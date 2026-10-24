import Foundation

public struct LayerResolver {
    let library: PackLibrary
    let tmux: TmuxQuerying
    let remote: RemoteQuerying?
    static let shells: Set = ["fish", "bash", "zsh", "sh"]

    public init(library: PackLibrary, tmux: TmuxQuerying, remote: RemoteQuerying?) {
        self.library = library; self.tmux = tmux; self.remote = remote
    }

    static let tabIndex = try! NSRegularExpression(pattern: #"^\[(\d+)/(\d+)\]\s*"#)

    /// `[n/m] ` that Kaku/WezTerm put before the title, split off
    static func splitTabIndex(_ title: String) -> (n: Int, m: Int, rest: String)? {
        let ns = title as NSString
        guard let r = tabIndex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)),
              let n = Int(ns.substring(with: r.range(at: 1))), let m = Int(ns.substring(with: r.range(at: 2))) else { return nil }
        return (n, m, ns.substring(from: r.range.upperBound))
    }

    /// The tty the user is looking at. With several tabs: `focused` (from the terminal itself) when it is one of them;
    /// else a `[n/m]` title prefix picks the n-th tab when there are exactly m, in the order the tabs' shells started;
    /// else a unique whole title word (case-insensitive) equal to the foreground process's name or display name
    /// (`vi` doesn't match `nvim-ish`). Otherwise nil, because a guessed layer is worse than fewer layers.
    public func chooseTTY(_ s: ProcessSnapshot, terminalPID: Int32, title: String?, focused: String? = nil) -> String? {
        let ttys = s.ttys(under: terminalPID)
        if ttys.count <= 1 { return ttys.first }
        if let focused, ttys.contains(focused) { return focused }
        guard let title else { return nil }
        let idx = Self.splitTabIndex(title)
        if let idx, idx.m == ttys.count, (1...idx.m).contains(idx.n) {
            // the tab's session leader is the terminal's direct child on that tty
            func started(_ t: String) -> Double {
                let p = s.children(of: terminalPID).filter { $0.tty == t }
                return (p.isEmpty ? s.procs.filter { $0.tty == t } : p).map(\.start).min() ?? .infinity
            }
            return ttys.sorted { started($0) < started($1) }[idx.n - 1]
        }
        let rest = RemoteTag.parse(idx?.rest ?? title).rest
        let words = Set(rest.lowercased().split { !($0.isLetter || $0.isNumber || "._+-".contains($0)) }.map(String.init))
        let hits = ttys.filter { t in
            s.foreground(tty: t).map { p in [p.name, Self.displayName(p.name, argv: p.argv)].contains { words.contains($0.lowercased()) } } ?? false
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// chain from the tty's foreground process up to the terminal, innermost first, without `login`
    func chain(_ s: ProcessSnapshot, tty: String, terminal pid: Int32) -> [ProcInfo] {
        s.foreground(tty: tty).map { s.chain(from: $0) { $0.pid == pid }.filter { $0.name != "login" } } ?? []
    }

    public func resolve(_ s: ProcessSnapshot, terminal: TerminalContext) -> [Layer] {
        var out = [Layer]()
        if let tty = chooseTTY(s, terminalPID: terminal.pid, title: terminal.windowTitle, focused: terminal.focusedTTY) {
            let title = terminal.windowTitle.map { Self.splitTabIndex($0)?.rest ?? $0 }
            out = chain(s, tty: tty, terminal: terminal.pid).flatMap { layers(for: $0, s, title: title) }
        } else {
            // ambiguous tabs: only the login shell, and only when every tab's is the same
            let shells = s.ttys(under: terminal.pid).map { chain(s, tty: $0, terminal: terminal.pid).last { Self.shells.contains($0.name) } }
            if let first = shells.first ?? nil, shells.allSatisfy({ $0?.name == first.name }) {
                out = [layer(first.name, argv: first.argv)]
            }
        }
        out.append(Layer(kind: .terminal, name: terminal.appName, packID: "app:\(terminal.bundleID)", reason: "menu keys"))
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// The app's layer; a browser window whose title shows a pack's app (`titles`) gets that pack's layer in front.
    public func resolveApp(bundleID: String, name: String, title: String? = nil) -> [Layer] {
        let own = library.pack(bundleID: bundleID)
        let app = Layer(kind: .app, name: name, packID: "app:\(bundleID)", reason: "menu keys" + (own.map { " and pack \($0.id) via apps" } ?? ""))
        guard own == nil, let p = library.pack(hostedIn: bundleID, title: title) else { return [app] }
        return [Layer(kind: .app, name: p.name, packID: p.id, reason: "titles of \(p.id) match the window title"), app]
    }

    /// Sets each app or terminal layer's `context` from the window title. `packs[i]` is the pack of `layers[i]`.
    public static func applyContexts(_ layers: [Layer], packs: [Pack?], title: String?) -> [Layer] {
        zip(layers, packs).map { l, p in
            var l = l
            if l.kind == .app || l.kind == .terminal { l.context = p?.activeContext(title: title)?.name }
            return l
        }
    }

    func layer(_ name: String, argv: [String], host: String? = nil) -> Layer {
        let kind: LayerKind = Self.shells.contains(name) ? .shell : name == "tmux" ? .multiplexer : .program
        let pick = library.pick(process: name, argv: argv)
        var l = Layer(kind: kind, name: kind == .program ? Self.displayName(name, argv: argv) : name,
                      packID: pick?.pack.id, host: host, reason: pick?.reason)
        l.process = name; l.argv = argv
        return l
    }

    static let interpreters: Set = ["node", "python", "python3", "ruby", "perl", "bun", "deno"]

    public static func isInterpreter(_ name: String) -> Bool { interpreters.contains(name) || name.hasPrefix("python") }

    /// The script an interpreter runs: its first argument that is not an option.
    public static func script(_ name: String, argv: [String]) -> String? {
        isInterpreter(name) ? argv.dropFirst().first { !$0.hasPrefix("-") } : nil
    }

    /// What the user typed: the script for interpreters, else argv[0]'s basename
    /// (Claude Code's executable is a version-numbered file, but argv[0] is `claude`).
    static func displayName(_ name: String, argv: [String]) -> String {
        func base(_ s: String) -> String { (s as NSString).lastPathComponent }
        if let script = script(name, argv: argv) {
            let file = (base(script) as NSString).deletingPathExtension
            let generic: Set = ["cli", "index", "main", "__main__"]
            return generic.contains(file) ? base((script as NSString).deletingLastPathComponent) : file
        }
        let a0 = argv.first.map { base(String($0.drop { $0 == "-" })) } ?? ""
        return a0.isEmpty ? name : a0
    }

    func layers(for p: ProcInfo, _ s: ProcessSnapshot, title: String?, depth: Int = 0) -> [Layer] {
        switch p.name {
        case "tmux": return paneLayers(client: p, s, title: title, depth: depth) + [layer(p.name, argv: p.argv)]
        case "ssh", "mosh-client": return remoteLayers(p, title: title)
        default: return [layer(p.name, argv: p.argv)]
        }
    }

    /// layers of the pane the tmux client `p` shows, innermost first; empty when unknown
    func paneLayers(client p: ProcInfo, _ s: ProcessSnapshot, title: String?, depth: Int) -> [Layer] {
        guard depth < 4, let tty = p.tty, let bin = p.path ?? p.argv.first.flatMap({ $0.hasPrefix("/") ? $0 : nil }),
              let c = tmux.clients(tmux: bin, server: TmuxArgs.server(p.argv)).first(where: { $0.clientTTY == tty }),
              let fg = s.foreground(tty: c.paneTTY) else { return [] }
        return s.chain(from: fg) { $0.name == "tmux" && $0.tty == nil }
            .flatMap { layers(for: $0, s, title: title, depth: depth + 1) }
    }

    func remoteLayers(_ p: ProcInfo, title: String?) -> [Layer] {
        if let tag = title.flatMap({ RemoteTag.parse($0).tag }) {
            return tag.layers.reversed().map { layer($0, argv: [$0], host: tag.host) }
                + [Layer(kind: .remote, name: tag.host, host: tag.host)]
        }
        guard p.name == "ssh" else {
            let host = p.argv.dropFirst().last { !$0.hasPrefix("-") } ?? p.name
            return [Layer(kind: .remote, name: host, host: host)]
        }
        let host = SSHArgs.parse(p.argv)?.host ?? p.name
        if let cmd = remote?.paneCommand(sshArgv: p.argv) {
            return [layer(cmd, argv: [cmd], host: host), Layer(kind: .remote, name: host, host: host)]
        }
        return [Layer(kind: .remote, name: host, host: host)]
    }
}
