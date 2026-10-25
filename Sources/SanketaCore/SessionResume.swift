import Foundation

/// Resumes a ramabana session with `ramabana --resume <id>`: in a new window of the tmux session that the user used
/// last, when a tmux client is attached; else the caller opens a new terminal window with `script`.
public struct SessionResume {
    let runner: CommandRunning
    /// tmux programs and their servers (`-S path`, `-L name` or none), in the order to try
    let servers: [(tmux: String, server: [String])]
    /// the ramabana program; the shell of the new window finds `ramabana` when this is nil
    let ramabana: String?

    public init(runner: CommandRunning, servers: [(tmux: String, server: [String])], ramabana: String?) {
        self.runner = runner; self.servers = servers; self.ramabana = ramabana
    }

    /// The command that resumes session `id`; nil for an id that is not safe in a shell word.
    public func command(_ id: String) -> String? {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { return nil }
        return "\(ramabana.map(Self.quote) ?? "ramabana") --resume \(id)"
    }

    /// `s` in single quotes for a POSIX shell.
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The session of the attached client with the latest activity, from `list-clients` lines `<activity>\t<id>`.
    static func lastSession(_ out: String) -> String? {
        out.split(separator: "\n").compactMap { l -> (Int, String)? in
            let f = l.split(separator: "\t").map(String.init)
            guard f.count == 2, let t = Int(f[0]), f[1].hasPrefix("$") else { return nil }
            return (t, f[1])
        }.max { $0.0 < $1.0 }?.1
    }

    /// Opens a tmux window that runs the resume command. False: no attached client, or tmux failed.
    public func inTmux(_ id: String) -> Bool {
        guard let cmd = command(id) else { return false }
        for (tmux, server) in servers {
            guard let out = runner.run(tmux, server + ["list-clients", "-F", "#{client_activity}\t#{session_id}"]),
                  let session = Self.lastSession(out) else { continue }
            if runner.run(tmux, server + ["new-window", "-t", "\(session):", "-n", "resume", cmd]) != nil { return true }
        }
        return false
    }

    /// A `.command` script for a terminal app that runs the resume command in a login shell.
    public func script(_ id: String) -> String? {
        command(id).map { "#!/bin/zsh -l\nclear\nexec \($0)\n" }
    }

    /// The tmux servers to try: those that running tmux clients name (`argv`), then the default server; each with the
    /// first tmux program found.
    public static func servers(clients: [(path: String?, argv: [String])], fallback: [String]) -> [(tmux: String, server: [String])] {
        var out: [(tmux: String, server: [String])] = [], seen = Set<[String]>()
        let bin = clients.compactMap(\.path).first ?? fallback.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { return [] }
        for s in clients.map({ TmuxArgs.server($0.argv) }) + [[]] where seen.insert(s).inserted { out.append((bin, s)) }
        return out
    }
}
