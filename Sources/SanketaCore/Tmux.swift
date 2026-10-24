import Foundation

public struct TmuxClient: Hashable {
    public var clientTTY: String
    public var paneTTY: String
    public var paneCommand: String
    public init(clientTTY: String, paneTTY: String, paneCommand: String) {
        self.clientTTY = clientTTY; self.paneTTY = paneTTY; self.paneCommand = paneCommand
    }
}

public enum Tmux {
    public static let clientsFormat = "#{client_tty}\t#{pane_tty}\t#{pane_current_command}"
    static let group = "Live bindings"

    public static func parseClients(_ s: String) -> [TmuxClient] {
        s.split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t", omittingEmptySubsequences: false).map { $0.replacingOccurrences(of: "/dev/", with: "") }
            return f.count == 3 ? TmuxClient(clientTTY: f[0], paneTTY: f[1], paneCommand: f[2]) : nil
        }
    }

    static func mouseKey(_ k: String) -> Bool { ["Mouse", "Wheel", "Click"].contains { k.contains($0) } }

    static func unescape(_ k: String) -> String {
        var out = "", esc = false
        for c in k { if c == "\\" && !esc { esc = true } else { out.append(c); esc = false } }
        return out
    }

    public static func parseKeys(_ s: String) -> [KeyEntry] {
        s.split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            func next() -> Substring? {
                rest = rest.drop { $0 == " " }
                guard !rest.isEmpty else { return nil }
                let w = rest.prefix { $0 != " " }
                rest = rest.dropFirst(w.count)
                return w
            }
            guard next() == "bind-key" else { return nil }
            var table = "prefix"
            while case let t = rest.drop(while: { $0 == " " }).prefix(while: { $0 != " " }), t.count == 2, t.first == "-", t.last!.isLetter {
                let f = next()!
                if f == "-T" { table = String(next() ?? "") } else if f == "-N" { _ = next() }
            }
            guard let k = next() else { return nil }
            let cmd = rest.drop { $0 == " " }.description
            let key = unescape(String(k))
            guard !cmd.isEmpty, !mouseKey(key) else { return nil }
            switch table {
            // the title is the raw command, which can hold hosts and paths, so it stays on this Mac
            case "prefix": return KeyEntry(keys: "prefix \(key)", action: cmd, group: group, command: cmd, staysOnMac: true)
            case "root": return KeyEntry(keys: key, action: cmd, group: group, command: cmd, staysOnMac: true)
            default: return nil
            }
        }
    }

    public static func mergeLive(_ pack: Pack, live: [KeyEntry]) -> Pack {
        var out = pack, merged: [KeyEntry] = [], used = Set<Int>()
        for (i, l) in live.enumerated() {
            if let c = l.command, let p = pack.keys.first(where: { $0.command == c }) {
                var e = p; e.keys = l.keys; merged.append(e); used.insert(i)
            }
        }
        let kept = pack.keys.filter { $0.command == nil }
        let extra = live.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        out.keys = kept + merged + extra
        return out
    }
}

public enum TmuxArgs {
    /// tmux options that take a value
    static let valued: Set<Character> = ["c", "f", "L", "S", "T"]

    /// The server a tmux client talks to, from its argv: `["-S", path]`, `["-L", name]`, or `[]` for the default.
    /// `-S` wins over `-L`, as in tmux; options stop at the first word that is not one.
    public static func server(_ argv: [String]) -> [String] {
        var L: String?, S: String?
        var i = 1
        while i < argv.count, argv[i].hasPrefix("-"), argv[i] != "-", argv[i] != "--" {
            let a = Array(argv[i].dropFirst())
            for (j, c) in a.enumerated() where valued.contains(c) {
                let rest = String(a[(j + 1)...])
                let v = rest.isEmpty ? (i + 1 < argv.count ? argv[i + 1] : nil) : rest
                if rest.isEmpty { i += 1 }
                if c == "L" { L = v } else if c == "S" { S = v }
                break
            }
            i += 1
        }
        return S.map { ["-S", $0] } ?? L.map { ["-L", $0] } ?? []
    }
}

public protocol TmuxQuerying {
    /// `server` is `TmuxArgs.server` of the client's argv; empty means the default server
    func clients(tmux: String, server: [String]) -> [TmuxClient]
    func liveKeys(tmux: String, server: [String]) -> (prefix: String?, keys: [KeyEntry])
}

public extension TmuxQuerying {
    func clients(tmux: String) -> [TmuxClient] { clients(tmux: tmux, server: []) }
    func liveKeys(tmux: String) -> (prefix: String?, keys: [KeyEntry]) { liveKeys(tmux: tmux, server: []) }
}

public struct TmuxQuery: TmuxQuerying {
    let runner: CommandRunning
    /// the server to use when the client's argv names none; tests set a private socket here
    let socket: String?
    public init(runner: CommandRunning, socket: String? = nil) { self.runner = runner; self.socket = socket }

    func run(_ tmux: String, _ server: [String], _ args: [String]) -> String? {
        runner.run(tmux, (server.isEmpty ? socket.map { ["-L", $0] } ?? [] : server) + args, timeout: 1.0)
    }

    public func clients(tmux: String, server: [String]) -> [TmuxClient] {
        run(tmux, server, ["list-clients", "-F", Tmux.clientsFormat]).map(Tmux.parseClients) ?? []
    }

    public func liveKeys(tmux: String, server: [String]) -> (prefix: String?, keys: [KeyEntry]) {
        // list-keys succeeds with defaults even without a server; show fails, so it gates liveness.
        guard let p = run(tmux, server, ["show", "-gv", "prefix"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              let k = run(tmux, server, ["list-keys"]) else { return (nil, []) }
        return (p.isEmpty ? nil : p, Tmux.parseKeys(k))
    }
}
