import AppKit
import Combine
import SanketaCore

public struct Context: Equatable {
    public var appName: String
    public var bundleID: String
    public var layers: [Layer]
    public var packs: [Pack]
    public var axTrusted: Bool
    /// the app's menu read was empty or hit the AX timeout; the monitor reads it once more
    public var menuIncomplete = false
    /// a pack (bundled or user) lists the app's bundle id in `apps`; without one, the panel shows "Make a pack"
    public var appHasPack = false
    public init(appName: String = "", bundleID: String = "", layers: [Layer] = [], packs: [Pack] = [], axTrusted: Bool = false) {
        self.appName = appName; self.bundleID = bundleID; self.layers = layers; self.packs = packs; self.axTrusted = axTrusted
    }
}

/// The lines of the last compute that tell how the engine found the stack, for Copy Debug Info. Shared by copies of a
/// `ContextEngine`.
public final class Trace: @unchecked Sendable {
    private var store: [String] = []
    private let lock = NSLock()
    public var lines: [String] { lock.withLock { store } }
    func set(_ l: [String]) { lock.withLock { store = l } }
    func add(_ l: String) { lock.withLock { store.append(l) } }
}

/// Passes each call to `base` and adds each `clients` answer to `trace`.
struct TracedTmux: TmuxQuerying {
    let base: TmuxQuerying, trace: Trace
    func clients(tmux: String, server: [String]) -> [TmuxClient] {
        let c = base.clients(tmux: tmux, server: server)
        let answer = c.isEmpty ? "none" : c.map { "\($0.clientTTY) > \($0.paneTTY) \($0.paneCommand)" }.joined(separator: ", ")
        trace.add((["tmux"] + server).joined(separator: " ") + " clients: " + answer)
        return c
    }
    func liveKeys(tmux: String, server: [String]) -> (prefix: String?, keys: [KeyEntry]) { base.liveKeys(tmux: tmux, server: server) }
}

/// Time-limited cache shared by copies of a `ContextEngine`.
final class TTLCache<K: Hashable, V>: @unchecked Sendable {
    let ttl: TimeInterval
    private var store: [K: (Date, V)] = [:]
    private let lock = NSLock()
    init(ttl: TimeInterval) { self.ttl = ttl }

    /// Cached value for `k`, else `make()`; results failing `keep` are returned but not stored.
    func get(_ k: K, keep: (V) -> Bool = { _ in true }, _ make: () -> V) -> V {
        if let v = lock.withLock({ store[k].flatMap { Date().timeIntervalSince($0.0) < ttl ? $0.1 : nil } }) { return v }
        let v = make()
        if keep(v) { lock.withLock { store[k] = (Date(), v) } }
        return v
    }
}

/// The answer for the last key only: asked again when the key changes or after `clear()`. After a new key it is asked
/// until two answers in a row agree, because the source can lag behind the key (Kaku's CLI names the old tab for a
/// moment after the window title shows the new one). Answers that keep changing get `quickTries` quick tries; then,
/// as for a failed answer (`failed`), the source is asked at most once per `retry` seconds. So a CLI that failed once
/// does not stay failed, and a CLI that fails or changes all the time does not run at each poll.
final class LastAnswer<K: Equatable, V: Equatable>: @unchecked Sendable {
    private var last: (key: K, value: V, at: Date, sure: Bool, tries: Int)?
    private let lock = NSLock()
    let retry: TimeInterval
    let failed: (V) -> Bool
    static var quickTries: Int { 3 }
    var now: () -> Date = Date.init

    init(retry: TimeInterval = .infinity, failed: @escaping (V) -> Bool = { _ in false }) { self.retry = retry; self.failed = failed }

    func get(_ k: K, _ make: () -> V) -> V {
        let t = now()
        let l = lock.withLock { last }
        if let l, l.key == k {
            let waiting = t.timeIntervalSince(l.at) < retry
            if l.sure, !failed(l.value) || waiting { return l.value }
            if !l.sure, l.tries >= Self.quickTries, waiting { return l.value }
        }
        let v = make()
        let same = l.map { $0.key == k } ?? false
        let sure = same && l?.value == v
        let tries = same && !sure ? (l?.tries ?? 0) + 1 : 1
        lock.withLock { last = (k, v, t, sure, tries) }
        return v
    }
    func clear() { lock.withLock { last = nil } }
}

/// Menu reads by pid for 60 s. A slow read (it may have hit the AX timeout) is kept but read once more. After an empty
/// or slow read, the app's reads get the long timeout (`AXReader.slowTimeout`): an Electron app such as Slack can need
/// more than 0.5 s to give its menu bar.
final class MenuCache: @unchecked Sendable {
    private var store: [pid_t: (at: Date, shortcuts: [MenuShortcut], reread: Bool)] = [:]
    private var needsLong: Set<pid_t> = []
    private let lock = NSLock()
    let ttl: TimeInterval = 60
    /// the clock that times a read; tests set it
    var now: () -> Date = Date.init

    /// Drops the menus and the long timeout of `pid`, when its app quits: the pid can come back for another app.
    func forget(_ pid: pid_t) { lock.withLock { store[pid] = nil; needsLong.remove(pid) } }

    /// The shortcuts, and false when this read was empty or the first slow one. `read` gets the timeout to use.
    func get(_ pid: pid_t, slow: TimeInterval, _ read: (TimeInterval) -> [MenuShortcut]) -> (shortcuts: [MenuShortcut], full: Bool) {
        let (e, long) = lock.withLock { (store[pid].flatMap { now().timeIntervalSince($0.at) < ttl ? $0 : nil }, needsLong.contains(pid)) }
        if let e, !e.reread { return (e.shortcuts, true) }
        let t0 = now()
        let m = read(long ? AXReader.slowTimeout : AXReader.timeout)
        let isSlow = now().timeIntervalSince(t0) >= slow
        if m.isEmpty || isSlow { lock.withLock { _ = needsLong.insert(pid) } }
        // the second read is final; an empty read is never kept, so the next compute reads again
        let first = e == nil
        if !m.isEmpty { lock.withLock { store[pid] = (now(), m, isSlow && first) } }
        return (m.isEmpty ? e?.shortcuts ?? [] : m, !m.isEmpty && !(isSlow && first))
    }
}

public struct ContextEngine: @unchecked Sendable {
    public var config: Config
    public var library: PackLibrary
    let tmuxSocket: String?
    let remote = RemoteQuery(runner: ProcessRunner())
    let menus = MenuCache()
    let live = TTLCache<String, (prefix: String?, keys: [KeyEntry])>(ttl: 30)
    /// Kaku's focused tty for the last (pid, window, tab prefix, ttys); `resetChanges()` clears it on activation. A nil
    /// answer (the CLI failed) is asked again after `kakuRetry` seconds.
    let kakuFocus = LastAnswer<String, String?>(retry: ContextEngine.kakuRetry) { $0 == nil }
    static let kakuRetry: TimeInterval = 10
    let tmuxClients = TmuxClientStore()
    /// how the last compute found the stack: the chosen tty and each tmux answer; empty for an app that is not a terminal
    public let trace = Trace()
    // the outside world; tests put stand-ins here
    var runner: CommandRunning = ProcessRunner()
    var isTrusted: () -> Bool = { AXReader.isTrusted }
    var snapshot: (pid_t) -> ProcessSnapshot = { SysctlProcesses.snapshot(under: [$0]) }
    var focusedWindow: (pid_t) -> (title: String?, id: Int)? = { AXReader.focusedWindow(pid: $0) }
    var readMenu: (pid_t, TimeInterval) -> [MenuShortcut] = { AXReader.menuShortcuts(pid: $0, timeout: $1) }
    var kakuCLI: (pid_t) -> String? = { KakuQuery.cli(bundle: NSRunningApplication(processIdentifier: $0)?.bundleURL) }
    /// a menu read this slow may have hit the AX timeout
    var slowMenu: TimeInterval = AXReader.timeout

    public init(config: Config, library: PackLibrary, tmuxSocket: String? = nil) {
        self.config = config; self.library = library; self.tmuxSocket = tmuxSocket
    }

    var tmux: TmuxQuery { TmuxQuery(runner: runner, socket: tmuxSocket) }

    /// Forgets the change-driven answers (Kaku's focused tty, tmux clients), so the next compute asks again.
    public func resetChanges() { kakuFocus.clear(); tmuxClients.clear() }

    public func compute(pid: pid_t, bundleID: String, appName: String) -> Context {
        let trusted = isTrusted()
        var snap: ProcessSnapshot?
        let layers: [Layer], title: String?
        if config.terminals.contains(bundleID) {
            let s = snapshot(pid)
            snap = s
            let w = trusted ? focusedWindow(pid) : nil
            title = w?.title
            let ttys = s.ttys(under: pid), focused = focusedTTY(pid: pid, bundleID: bundleID, window: w, ttys: ttys)
            trace.set(["tty: " + (focused ?? "not chosen, \(ttys.count) ttys")])
            let tmux = TracedTmux(base: CachedTmux(base: self.tmux, store: tmuxClients, state: CachedTmux.state(s, title: title, window: w?.id)),
                                  trace: trace)
            layers = LayerResolver(library: library, tmux: tmux, remote: remote)
                .resolve(s, terminal: TerminalContext(pid: pid, bundleID: bundleID, appName: appName, windowTitle: title, focusedTTY: focused))
        } else {
            trace.set([])
            title = trusted && library.readsTitle(bundleID: bundleID) ? focusedWindow(pid)?.title : nil
            layers = LayerResolver(library: library, tmux: tmux, remote: remote).resolveApp(bundleID: bundleID, name: appName, title: title)
        }
        var incomplete = false
        let paired = layers.map { l -> Pack? in
            switch l.kind {
            case .app where l.packID == "app:\(bundleID)", .terminal:
                let (p, full) = menuPack(pid: pid, bundleID: bundleID, name: appName, trusted: trusted)
                incomplete = trusted && !full
                return p
            case .multiplexer where l.packID == "tmux" && l.host == nil:
                let c = snap.flatMap { tmuxClient($0, under: pid, argv: l.argv) }
                return library.packs["tmux"].map { tmuxPack($0, bin: c?.path, server: TmuxArgs.server(c?.argv ?? [])) }
            default: return l.packID.flatMap { library.packs[$0] }
            }
        }
        let packs = paired.compactMap { $0 }
        let withContexts = LayerResolver.applyContexts(layers, packs: paired, title: title)
        var c = Context(appName: appName, bundleID: bundleID, layers: withContexts, packs: packs, axTrusted: trusted)
        c.menuIncomplete = incomplete
        c.appHasPack = library.pack(bundleID: bundleID) != nil
        return c
    }

    /// menu shortcuts merged with any user pack whose `apps` lists the bundle id
    func appPack(pid: pid_t, bundleID: String, name: String, trusted: Bool) -> Pack {
        menuPack(pid: pid, bundleID: bundleID, name: name, trusted: trusted).pack
    }

    /// `appPack`, and false when the menu read was empty or the first slow one (the monitor then reads once more).
    func menuPack(pid: pid_t, bundleID: String, name: String, trusted: Bool) -> (pack: Pack, full: Bool) {
        let (shortcuts, full) = trusted ? menus.get(pid, slow: slowMenu) { readMenu(pid, $0) } : ([], true)
        let menu = MenuKeys.pack(bundleID: bundleID, name: name, shortcuts: shortcuts)
        guard let user = library.pack(bundleID: bundleID) else { return (menu, full) }
        var m = PackLibrary.merge(menu, user)
        m.id = menu.id
        return (m, full)
    }

    /// The tty of Kaku's focused pane from its own CLI, when it has more than one tty; nil if the CLI is missing or
    /// fails. Asked again only when the window, its `[n/m]` tab prefix or the ttys change, or after `resetChanges()`;
    /// a nil answer also after `kakuRetry` seconds.
    func focusedTTY(pid: pid_t, bundleID: String, window: (title: String?, id: Int)?, ttys: [String]) -> String? {
        guard bundleID == "fun.tw93.kaku", ttys.count > 1, let cli = kakuCLI(pid) else { return nil }
        let key = "\(pid)|\(window?.id ?? 0)|\(LayerResolver.tabKey(window?.title))|\(ttys.sorted())"
        return kakuFocus.get(key) { KakuQuery(runner: runner, cli: cli).focusedTTY(pid: pid, title: window?.title) }
    }

    /// Live keys of the server `server` (`TmuxArgs.server` of the client's argv), merged into `p`.
    func tmuxPack(_ p: Pack, bin: String?, server: [String] = []) -> Pack {
        guard let bin else { return p }
        // an empty read (server still starting, or a timeout) isn't cached
        let l = live.get(([bin] + server).joined(separator: " "), keep: { !$0.keys.isEmpty }) { tmux.liveKeys(tmux: bin, server: server) }
        var m = Tmux.mergeLive(p, live: l.keys)
        m.prefix = l.prefix ?? p.prefix
        return m
    }

    /// The tmux client below the terminal whose argv is `argv` (the tmux layer's), else the first one with a path.
    func tmuxClient(_ s: ProcessSnapshot, under pid: pid_t, argv: [String]?) -> ProcInfo? {
        var queue = [pid], seen = Set([pid]), first: ProcInfo?
        while !queue.isEmpty {
            for c in s.children(of: queue.removeFirst()) where seen.insert(c.pid).inserted {
                if c.name == "tmux", c.path != nil {
                    if c.argv == argv { return c }
                    first = first ?? c
                }
                queue.append(c.pid)
            }
        }
        return first
    }
}

@MainActor public final class ContextMonitor: ObservableObject {
    @Published public private(set) var context = Context()
    var engine: ContextEngine
    /// how the last compute found the stack (`ContextEngine.trace`), for Copy Debug Info
    public var trace: [String] { engine.trace.lines }
    let queue = DispatchQueue(label: "dev.sanketa.context", qos: .utility)
    var timer: Timer?
    var busy = false
    var observer: NSObjectProtocol?, quitObserver: NSObjectProtocol?
    /// makes the title watcher for a pid; tests put a fake here
    public typealias TitleWatcherFactory = (pid_t, @escaping (String?) -> Void) -> AnyObject?
    var makeWatcher: TitleWatcherFactory = { AXTitleWatcher(pid: $0, onChange: $1) }
    var isTrusted: () -> Bool = { AXReader.isTrusted }
    /// what a title change runs after the debounce; nil means `refresh()`
    var onTitleRefresh: (() -> Void)?
    var titleDebounce: TimeInterval = 0.1
    var titles: AnyObject?
    var watched: (pid: pid_t, bundleID: String)?
    /// pack id and scope token of the last title; nil inside means the title shows no pack
    var titleKey: String??
    var pendingTitle: Timer?
    /// more reads when the menu read was empty or timed out, after each wait in `menuRetryDelays`; only after an
    /// activation, never as a poll
    var menuRetry: Timer?
    var menuRetries = 0
    var menuRetryDelays = ContextMonitor.menuRetryDelays
    public nonisolated static let menuRetryDelays: [TimeInterval] = [0.5, 1, 2]
    /// what `refresh` computes; nil means the engine. Tests put a stand-in here.
    var computeContext: ((pid_t, String, String) -> Context)?

    public init(config: Config, library: PackLibrary) { engine = ContextEngine(config: config, library: library) }

    public func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self?.appTerminated(pid) }
        }
        activated(NSWorkspace.shared.frontmostApplication)
    }

    /// An app quit: its menu reads go from the cache.
    func appTerminated(_ pid: pid_t) { engine.menus.forget(pid) }

    /// New packs, and a new config when it changed: terminals and pollInterval apply at once.
    public func reload(config: Config? = nil, library: PackLibrary) {
        engine.library = library
        if let config, config != engine.config {
            engine.config = config
            return activated(NSWorkspace.shared.frontmostApplication)
        }
        if let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier {
            watchTitle(pid: app.processIdentifier, bundleID: bid)
        }
        refresh()
    }

    /// An app whose title picks a pack context (or hosts a pack) is not polled; its title changes push a refresh.
    /// With Sanketa itself in front, the watcher of the app behind it stays.
    func watchTitle(pid: pid_t, bundleID bid: String) {
        guard bid != Bundle.main.bundleIdentifier else { return }
        titles = nil; watched = nil; titleKey = nil
        pendingTitle?.invalidate()
        guard !engine.config.terminals.contains(bid), engine.library.readsTitle(bundleID: bid), isTrusted() else { return }
        watched = (pid, bid)
        titles = makeWatcher(pid) { [weak self] title in
            MainActor.assumeIsolated { self?.titleChanged(title, bundleID: bid) }
        }
    }

    /// Refreshes, after the debounce, only when the title gives another pack or scope token. A browser retitles its
    /// window on each tab switch and some pages tick their title; those changes cost one regex each.
    func titleChanged(_ title: String?, bundleID: String) {
        let key = engine.library.titleKey(bundleID: bundleID, title: title)
        if let k = titleKey, k == key { return }
        titleKey = .some(key)
        pendingTitle?.invalidate()
        let t = Timer(timeInterval: titleDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; (self.onTitleRefresh ?? { self.refresh() })() }
        }
        RunLoop.main.add(t, forMode: .common)
        pendingTitle = t
    }

    func activated(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        timer?.invalidate()
        timer = nil
        menuRetry?.invalidate(); menuRetry = nil; menuRetries = 0
        engine.resetChanges()
        if engine.config.terminals.contains(app.bundleIdentifier ?? "") {
            let interval = max(0.25, engine.config.pollInterval)
            let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.busy == false { self?.refresh() } }
            }
            t.tolerance = interval * 0.2
            timer = t
        }
        if let bid = app.bundleIdentifier { watchTitle(pid: app.processIdentifier, bundleID: bid) }
        refresh(app)
    }

    func refresh(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let app, let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier else { return }
        // Accessibility granted after the app came to the front: start the watcher now
        if titles == nil { watchTitle(pid: app.processIdentifier, bundleID: bid) }
        busy = true
        let engine = engine, pid = app.processIdentifier, name = app.localizedName ?? bid
        let compute = computeContext ?? { engine.compute(pid: $0, bundleID: $1, appName: $2) }
        queue.async {
            let c = compute(pid, bid, name)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if c != self.context { self.context = c }
                if c.menuIncomplete { self.retryMenu(app) }
            }
        }
    }

    /// An app that has just started can show no menu bar yet, and a busy one can miss the AX timeout: read again, up to
    /// `menuRetryDelays.count` times, each after a longer wait.
    func retryMenu(_ app: NSRunningApplication) {
        guard menuRetries < menuRetryDelays.count else { return }
        let delay = menuRetryDelays[menuRetries]
        menuRetries += 1
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(app) }
        }
        RunLoop.main.add(t, forMode: .common)
        menuRetry = t
    }
}
