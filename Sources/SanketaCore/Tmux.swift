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
            case "prefix": return KeyEntry(keys: "prefix \(key)", action: cmd, group: group, command: cmd)
            case "root": return KeyEntry(keys: key, action: cmd, group: group, command: cmd)
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

public protocol TmuxQuerying {
    func clients(tmux: String) -> [TmuxClient]
    func liveKeys(tmux: String) -> (prefix: String?, keys: [KeyEntry])
}

public struct TmuxQuery: TmuxQuerying {
    let runner: CommandRunning
    let socket: String?
    public init(runner: CommandRunning, socket: String? = nil) { self.runner = runner; self.socket = socket }

    func run(_ tmux: String, _ args: [String]) -> String? {
        runner.run(tmux, (socket.map { ["-L", $0] } ?? []) + args, timeout: 1.0)
    }

    public func clients(tmux: String) -> [TmuxClient] {
        run(tmux, ["list-clients", "-F", Tmux.clientsFormat]).map(Tmux.parseClients) ?? []
    }

    public func liveKeys(tmux: String) -> (prefix: String?, keys: [KeyEntry]) {
        // list-keys succeeds with defaults even without a server; show fails, so it gates liveness.
        guard let p = run(tmux, ["show", "-gv", "prefix"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              let k = run(tmux, ["list-keys"]) else { return (nil, []) }
        return (p.isEmpty ? nil : p, Tmux.parseKeys(k))
    }
}
