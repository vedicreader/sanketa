import AppKit
import Combine
import SanketaCore

public struct Context: Equatable {
    public var appName: String
    public var bundleID: String
    public var layers: [Layer]
    public var packs: [Pack]
    public var axTrusted: Bool
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

    func get(_ k: K, _ make: () -> V) -> V {
        if let v = lock.withLock({ store[k].flatMap { Date().timeIntervalSince($0.0) < ttl ? $0.1 : nil } }) { return v }
        let v = make()
        lock.withLock { store[k] = (Date(), v) }
        return v
    }
}

public struct ContextEngine: @unchecked Sendable {
    public var config: Config
    public var library: PackLibrary
    let tmux: TmuxQuery
    let menus = TTLCache<pid_t, [MenuShortcut]>(ttl: 60)
    let live = TTLCache<String, (prefix: String?, keys: [KeyEntry])>(ttl: 30)

    public init(config: Config, library: PackLibrary, tmuxSocket: String? = nil) {
        self.config = config; self.library = library
        tmux = TmuxQuery(runner: ProcessRunner(), socket: tmuxSocket)
    }

    public func compute(pid: pid_t, bundleID: String, appName: String) -> Context {
        let trusted = AXReader.isTrusted
        let resolver = LayerResolver(library: library, tmux: tmux, remote: nil)
        var snap: ProcessSnapshot?
        let layers: [Layer]
        if config.terminals.contains(bundleID) {
            let s = SysctlProcesses.snapshot()
            snap = s
            let title = trusted ? AXReader.focusedWindowTitle(pid: pid) : nil
            layers = resolver.resolve(s, terminal: TerminalContext(pid: pid, bundleID: bundleID, appName: appName, windowTitle: title))
        } else {
            layers = resolver.resolveApp(bundleID: bundleID, name: appName)
        }
        let packs = layers.compactMap { l -> Pack? in
            switch l.kind {
            case .app, .terminal: return appPack(pid: pid, bundleID: bundleID, name: appName, trusted: trusted)
            case .multiplexer where l.packID == "tmux" && l.host == nil:
                return library.packs["tmux"].map { tmuxPack($0, bin: snap.flatMap { tmuxBinary($0, under: pid) }) }
            default: return l.packID.flatMap { library.packs[$0] }
            }
        }
        return Context(appName: appName, bundleID: bundleID, layers: layers, packs: packs, axTrusted: trusted)
    }

    /// menu shortcuts merged with any user pack whose `apps` lists the bundle id
    func appPack(pid: pid_t, bundleID: String, name: String, trusted: Bool) -> Pack {
        let menu = MenuKeys.pack(bundleID: bundleID, name: name,
                                 shortcuts: trusted ? menus.get(pid) { AXReader.menuShortcuts(pid: pid) } : [])
        guard let user = library.pack(bundleID: bundleID) else { return menu }
        var m = PackLibrary.merge(menu, user)
        m.id = menu.id
        return m
    }

    func tmuxPack(_ p: Pack, bin: String?) -> Pack {
        guard let bin else { return p }
        let l = live.get(bin) { tmux.liveKeys(tmux: bin) }
        var m = Tmux.mergeLive(p, live: l.keys)
        m.prefix = l.prefix ?? p.prefix
        return m
    }

    /// path of the first tmux client below the terminal
    func tmuxBinary(_ s: ProcessSnapshot, under pid: pid_t) -> String? {
        var queue = [pid], seen = Set([pid])
        while !queue.isEmpty {
            for c in s.children(of: queue.removeFirst()) where seen.insert(c.pid).inserted {
                if c.name == "tmux", let p = c.path { return p }
                queue.append(c.pid)
            }
        }
        return nil
    }
}

@MainActor public final class ContextMonitor: ObservableObject {
    @Published public private(set) var context = Context()
    var engine: ContextEngine
    let queue = DispatchQueue(label: "dev.sanketa.context", qos: .utility)
    var timer: Timer?
    var busy = false
    var observer: NSObjectProtocol?

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

    public func reload(library: PackLibrary) {
        engine.library = library
        refresh()
    }

    func activated(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        timer?.invalidate()
        timer = nil
        if engine.config.terminals.contains(app.bundleIdentifier ?? "") {
            timer = Timer.scheduledTimer(withTimeInterval: engine.config.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if self?.busy == false { self?.refresh() } }
            }
        }
        refresh(app)
    }

    func refresh(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        guard let app, let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier else { return }
        busy = true
        let engine = engine, pid = app.processIdentifier, name = app.localizedName ?? bid
        queue.async {
            let c = engine.compute(pid: pid, bundleID: bid, appName: name)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                if c != self.context { self.context = c }
            }
        }
    }
}
