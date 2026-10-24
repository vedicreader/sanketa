import Foundation

/// The destination of an `ssh` command line, plus the options that decide which control socket it uses.
public struct SSHArgs: Equatable {
    /// as typed: `host`, `user@host` or `ssh://user@host:port`
    public var destination: String
    /// `-p -l -F -S -J` and `-o` settings that feed ControlPath's `%p %r %h %j`
    public var options: [String]

    static let valued = Set("plioJFLRDbcEeImOQSWwB")
    static let socketFlags: Set<Character> = ["p", "l", "F", "S", "J"]
    static let socketSettings: Set = ["port", "user", "hostname", "controlpath", "proxyjump"]

    /// The first non-option argument; anything after it is the remote command.
    public static func parse(_ argv: [String]) -> SSHArgs? {
        var opts = [String](), i = 1
        while i < argv.count {
            let a = argv[i]
            if a == "--" { return i + 1 < argv.count ? SSHArgs(destination: argv[i + 1], options: opts) : nil }
            guard a.hasPrefix("-"), a.count > 1 else { return SSHArgs(destination: a, options: opts) }
            for (n, c) in a.dropFirst().enumerated() where valued.contains(c) {
                let inline = String(a.dropFirst(n + 2))
                let value = inline.isEmpty ? (i + 1 < argv.count ? argv[i + 1] : "") : inline
                if inline.isEmpty { i += 1 }
                let key = value.split(whereSeparator: { $0 == "=" || $0 == " " }).first.map { $0.lowercased() } ?? ""
                if socketFlags.contains(c) || (c == "o" && socketSettings.contains(key)) { opts += ["-\(c)", value] }
                break
            }
            i += 1
        }
        return nil
    }

    public static func destination(_ argv: [String]) -> String? { parse(argv)?.destination }

    /// the bare host name, for display
    public var host: String {
        var d = Substring(destination)
        if d.hasPrefix("ssh://") { d = d.dropFirst(6) }
        if let at = d.lastIndex(of: "@") { d = d[d.index(after: at)...] }
        if d.hasPrefix("["), let close = d.firstIndex(of: "]") { return String(d[d.index(after: d.startIndex)..<close]) }
        if destination.hasPrefix("ssh://"), let colon = d.lastIndex(of: ":") { d = d[..<colon] }
        return String(d)
    }
}

/// Asks the remote tmux for its pane's command, but only over an already open ControlMaster connection:
/// `BatchMode=yes` and `-O check` mean it never prompts and never opens a new connection.
public struct RemoteQuery: RemoteQuerying {
    let runner: CommandRunning
    let cacheSeconds: Double
    let cache = Cache()
    static let ssh = "/usr/bin/ssh"

    final class Cache: @unchecked Sendable {
        private var store: [[String]: (Date, String?)] = [:]
        private let lock = NSLock()
        func get(_ k: [String], ttl: Double, _ make: () -> String?) -> String? {
            if let hit = lock.withLock({ store[k] }), Date().timeIntervalSince(hit.0) < ttl { return hit.1 }
            let v = make()
            lock.withLock { store[k] = (Date(), v) }
            return v
        }
    }

    public init(runner: CommandRunning, cacheSeconds: Double = 5) { self.runner = runner; self.cacheSeconds = cacheSeconds }

    public func paneCommand(sshArgv: [String]) -> String? {
        guard let a = SSHArgs.parse(sshArgv) else { return nil }
        // never prompt, and never start a master or a fresh connection if the old master died after the check
        let base = ["-o", "BatchMode=yes", "-o", "ControlMaster=no", "-o", "ControlPersist=no"] + a.options
        return cache.get(base + [a.destination], ttl: cacheSeconds) {
            guard runner.run(Self.ssh, base + ["-O", "check", a.destination], timeout: 1) != nil else { return nil }
            // ssh joins arguments into a remote shell line, where an unquoted `#` would start a comment
            let out = runner.run(Self.ssh, base + [a.destination, "tmux", "display", "-p", "'#{pane_current_command}'"], timeout: 2)
            return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
