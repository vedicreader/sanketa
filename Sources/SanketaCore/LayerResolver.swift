import Foundation

public struct LayerResolver {
    let library: PackLibrary
    let tmux: TmuxQuerying
    let remote: RemoteQuerying?
    static let shells: Set = ["fish", "bash", "zsh", "sh"]

    public init(library: PackLibrary, tmux: TmuxQuerying, remote: RemoteQuerying?) {
        self.library = library; self.tmux = tmux; self.remote = remote
    }

    /// The tty the user is looking at. With several tabs, only a unique window-title match picks one;
    /// otherwise nil, because a guessed layer is worse than fewer layers.
    public func chooseTTY(_ s: ProcessSnapshot, terminalPID: Int32, title: String?) -> String? {
        let ttys = s.ttys(under: terminalPID)
        if ttys.count <= 1 { return ttys.first }
        guard let rest = title.map({ RemoteTag.parse($0).rest }) else { return nil }
        let hits = ttys.filter { t in s.foreground(tty: t).map { rest.contains($0.name) } ?? false }
        return hits.count == 1 ? hits[0] : nil
    }

    /// chain from the tty's foreground process up to the terminal, innermost first, without `login`
    func chain(_ s: ProcessSnapshot, tty: String, terminal pid: Int32) -> [ProcInfo] {
        s.foreground(tty: tty).map { s.chain(from: $0) { $0.pid == pid }.filter { $0.name != "login" } } ?? []
    }

    public func resolve(_ s: ProcessSnapshot, terminal: TerminalContext) -> [Layer] {
        var out = [Layer]()
        if let tty = chooseTTY(s, terminalPID: terminal.pid, title: terminal.windowTitle) {
            out = chain(s, tty: tty, terminal: terminal.pid).flatMap { layers(for: $0, s, title: terminal.windowTitle) }
        } else {
            // ambiguous tabs: only the login shell, and only when every tab's is the same
            let shells = s.ttys(under: terminal.pid).map { chain(s, tty: $0, terminal: terminal.pid).last { Self.shells.contains($0.name) } }
            if let first = shells.first ?? nil, shells.allSatisfy({ $0?.name == first.name }) {
                out = [layer(first.name, argv: first.argv)]
            }
        }
        out.append(Layer(kind: .terminal, name: terminal.appName, packID: "app:\(terminal.bundleID)"))
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    public func resolveApp(bundleID: String, name: String) -> [Layer] {
        [Layer(kind: .app, name: name, packID: "app:\(bundleID)")]
    }

    func layer(_ name: String, argv: [String], host: String? = nil) -> Layer {
        let kind: LayerKind = Self.shells.contains(name) ? .shell : name == "tmux" ? .multiplexer : .program
        return Layer(kind: kind, name: kind == .program ? Self.displayName(name, argv: argv) : name,
                     packID: library.pack(process: name, argv: argv)?.id, host: host)
    }

    static let interpreters: Set = ["node", "python", "python3", "ruby", "perl", "bun", "deno"]

    /// What the user typed: the script for interpreters, else argv[0]'s basename
    /// (Claude Code's executable is a version-numbered file, but argv[0] is `claude`).
    static func displayName(_ name: String, argv: [String]) -> String {
        func base(_ s: String) -> String { (s as NSString).lastPathComponent }
        if interpreters.contains(name) || name.hasPrefix("python"), let script = argv.dropFirst().first(where: { !$0.hasPrefix("-") }) {
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
              let c = tmux.clients(tmux: bin).first(where: { $0.clientTTY == tty }),
              let fg = s.foreground(tty: c.paneTTY) else { return [] }
        return s.chain(from: fg) { $0.name == "tmux" && $0.tty == nil }
            .flatMap { layers(for: $0, s, title: title, depth: depth + 1) }
    }

    func remoteLayers(_ p: ProcInfo, title: String?) -> [Layer] {
        if let tag = title.flatMap({ RemoteTag.parse($0).tag }) {
            return tag.layers.reversed().map { layer($0, argv: [$0], host: tag.host) }
                + [Layer(kind: .remote, name: tag.host, host: tag.host)]
        }
        let host = p.argv.dropFirst().last { !$0.hasPrefix("-") } ?? p.name
        if let cmd = remote?.paneCommand(sshArgv: p.argv) {
            return [layer(cmd, argv: [cmd], host: host), Layer(kind: .remote, name: host, host: host)]
        }
        return [Layer(kind: .remote, name: host, host: host)]
    }
}
