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
    public init(appName: String = "", bundleID: String = "", layers: [Layer] = [], packs: [Pack] = [], axTrusted: Bool = false) {
        self.appName = appName; self.bundleID = bundleID; self.layers = layers; self.packs = packs; self.axTrusted = axTrusted
    }
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

public struct ContextEngine: @unchecked Sendable {
    public var config: Config
    public var library: PackLibrary
    let tmux: TmuxQuery
    let remote = RemoteQuery(runner: ProcessRunner())
    let menus = TTLCache<pid_t, [MenuShortcut]>(ttl: 60)
    let live = TTLCache<String, (prefix: String?, keys: [KeyEntry])>(ttl: 30)
    /// Kaku's focused tty by pid, title and ttys: a new tab, window or title asks the CLI again, else every 5 s
    let kakuFocus = TTLCache<String, String?>(ttl: 5)

    public init(config: Config, library: PackLibrary, tmuxSocket: String? = nil) {
        self.config = config; self.library = library
        tmux = TmuxQuery(runner: ProcessRunner(), socket: tmuxSocket)
    }

    public func compute(pid: pid_t, bundleID: String, appName: String) -> Context {
        let trusted = AXReader.isTrusted
        let resolver = LayerResolver(library: library, tmux: tmux, remote: remote)
        var snap: ProcessSnapshot?
        let layers: [Layer], title: String?
        if config.terminals.contains(bundleID) {
            let s = SysctlProcesses.snapshot(under: [pid])
            snap = s
            title = trusted ? AXReader.focusedWindowTitle(pid: pid) : nil
            let focused = focusedTTY(pid: pid, bundleID: bundleID, title: title, ttys: s.ttys(under: pid))
            layers = resolver.resolve(s, terminal: TerminalContext(pid: pid, bundleID: bundleID, appName: appName,
                                                                   windowTitle: title, focusedTTY: focused))
        } else {
            title = trusted && library.readsTitle(bundleID: bundleID) ? AXReader.focusedWindowTitle(pid: pid) : nil
            layers = resolver.resolveApp(bundleID: bundleID, name: appName, title: title)
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
        return c
    }

    /// menu shortcuts merged with any user pack whose `apps` lists the bundle id
    func appPack(pid: pid_t, bundleID: String, name: String, trusted: Bool) -> Pack {
        menuPack(pid: pid, bundleID: bundleID, name: name, trusted: trusted).pack
    }

    /// `appPack`, and false when the menu read was empty or slow enough to have hit the AX timeout (not cached).
    func menuPack(pid: pid_t, bundleID: String, name: String, trusted: Bool) -> (pack: Pack, full: Bool) {
        var full = true
        let shortcuts = !trusted ? [] : menus.get(pid, keep: { !$0.isEmpty && full }) {
            let t0 = Date()
            let m = AXReader.menuShortcuts(pid: pid)
            full = !m.isEmpty && Date().timeIntervalSince(t0) < AXReader.timeout
            return m
        }
        let menu = MenuKeys.pack(bundleID: bundleID, name: name, shortcuts: shortcuts)
        guard let user = library.pack(bundleID: bundleID) else { return (menu, full) }
        var m = PackLibrary.merge(menu, user)
        m.id = menu.id
        return (m, full)
    }

    /// The tty of Kaku's focused pane from its own CLI, when it has more than one tty; nil if the CLI is missing or fails.
    func focusedTTY(pid: pid_t, bundleID: String, title: String?, ttys: [String]) -> String? {
        guard bundleID == "fun.tw93.kaku", ttys.count > 1,
              let cli = KakuQuery.cli(bundle: NSRunningApplication(processIdentifier: pid)?.bundleURL) else { return nil }
        return kakuFocus.get("\(pid)|\(title ?? "")|\(ttys.sorted())") { KakuQuery(runner: ProcessRunner(), cli: cli).focusedTTY(pid: pid) }
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
    let queue = DispatchQueue(label: "dev.sanketa.context", qos: .utility)
    var timer: Timer?
    var busy = false
    var observer: NSObjectProtocol?
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
    /// one more read after `menuRetryDelay` when the menu read was empty or timed out; once for each activation
    var menuRetry: Timer?
    var menuRetried = false
    var menuRetryDelay: TimeInterval = 1.0
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
        activated(NSWorkspace.shared.frontmostApplication)
    }

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
        menuRetry?.invalidate(); menuRetry = nil; menuRetried = false
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

    /// An app that has just started can show no menu bar yet, and a busy one can miss the AX timeout: read once more.
    func retryMenu(_ app: NSRunningApplication) {
        guard !menuRetried else { return }
        menuRetried = true
        let t = Timer(timeInterval: menuRetryDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(app) }
        }
        RunLoop.main.add(t, forMode: .common)
        menuRetry = t
    }
}
