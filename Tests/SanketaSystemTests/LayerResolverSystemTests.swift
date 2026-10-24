import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// A private tmux server stands in for the terminal app: its server pid is `TerminalContext.pid`.
@Suite(.serialized) struct LayerResolverSystemTests {
    let r = ProcessRunner()
    let outer = "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-outer"
    let inner = "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-inner"

    func tmux(_ sock: String, _ args: [String]) -> String? { r.run(tmuxBin, ["-L", sock] + args, timeout: 3.0) }

    func startOuter(_ cmd: [String]) throws -> Int32 {
        _ = try #require(tmux(outer, ["-f", "/dev/null", "new", "-d", "-s", "outer", "-x", "200", "-y", "50"] + cmd))
        return try #require(tmux(outer, ["display", "-p", "-t", "outer", "#{pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }

    func snapshot(until ok: (ProcessSnapshot) -> Bool) -> ProcessSnapshot {
        let end = Date().addingTimeInterval(5)
        var s = SysctlProcesses.snapshot()
        while !ok(s) && Date() < end {
            Thread.sleep(forTimeInterval: 0.1)
            s = SysctlProcesses.snapshot()
        }
        return s
    }

    func library() throws -> PackLibrary {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for id in ["fish", "tmux", "htop"] {
            try "id = \"\(id)\"\nname = \"\(id)\"\nprocesses = [\"\(id)\"]\n"
                .write(to: d.appendingPathComponent("\(id).toml"), atomically: true, encoding: .utf8)
        }
        let lib = PackLibrary.load(bundled: d, user: nil)
        try #require(lib.packs.count == 3 && lib.errors.isEmpty)
        return lib
    }

    func term(_ pid: Int32) -> TerminalContext {
        TerminalContext(pid: pid, bundleID: "test.terminal", appName: "TestTerm", windowTitle: nil)
    }

    @Test func resolveRealNestedTmuxHtop() throws {
        defer {
            _ = tmux(inner, ["kill-server"])
            _ = tmux(outer, ["kill-server"])
        }
        let server = try startOuter(["/opt/homebrew/bin/fish", "--no-config"])
        // SHELL makes the inner server's default shell fish regardless of the user's login shell.
        _ = try #require(tmux(outer, ["send-keys", "-t", "outer",
            "set -gx SHELL /opt/homebrew/bin/fish; /opt/homebrew/bin/tmux -L \(inner) -f /dev/null new -s inner", "Enter"]))
        let end = Date().addingTimeInterval(5)
        while tmux(inner, ["has-session", "-t", "inner"]) == nil && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        _ = try #require(tmux(inner, ["send-keys", "-t", "inner", "/opt/homebrew/bin/htop", "Enter"]))
        let s = snapshot { $0.procs.contains { $0.name == "htop" && $0.argv.first == "/opt/homebrew/bin/htop" } }
        let res = LayerResolver(library: try library(), tmux: TmuxQuery(runner: r, socket: inner), remote: nil)
        let ls = res.resolve(s, terminal: term(server))
        #expect(ls.map(\.name) == ["htop", "fish", "tmux", "TestTerm"])
        #expect(ls.map(\.packID) == ["htop", "fish", "tmux", "app:test.terminal"])
        #expect(ls.map(\.kind) == [.program, .shell, .multiplexer, .terminal])
    }

    @Test func resolveRealSingleTTY() throws {
        defer { _ = tmux(outer, ["kill-server"]) }
        let server = try startOuter(["/bin/sleep", "30"])
        let s = snapshot { $0.children(of: server).contains { $0.name == "sleep" } }
        let res = LayerResolver(library: try library(), tmux: TmuxQuery(runner: r, socket: inner), remote: nil)
        let ls = res.resolve(s, terminal: term(server))
        #expect(ls.map(\.name) == ["sleep", "TestTerm"])
        #expect(ls.map(\.packID) == [nil, "app:test.terminal"])
    }

    /// Two tabs (outer panes): one runs an inner tmux client, the other plain fish; no title, so no guessed tmux layer.
    @Test func resolveRealTwoTabsDoesNotGuessTmux() throws {
        defer {
            _ = tmux(inner, ["kill-server"])
            _ = tmux(outer, ["kill-server"])
        }
        // the tmux tab is the newer one, so the old newest-process fallback would have picked it
        let server = try startOuter(["/opt/homebrew/bin/fish", "--no-config"])
        _ = try #require(tmux(outer, ["new-window", "-d", "-t", "outer:1", "/opt/homebrew/bin/fish", "--no-config"]))
        _ = try #require(tmux(outer, ["send-keys", "-t", "outer:1",
            "set -gx SHELL /opt/homebrew/bin/fish; /opt/homebrew/bin/tmux -L \(inner) -f /dev/null new -s inner", "Enter"]))
        let end = Date().addingTimeInterval(5)
        while tmux(inner, ["has-session", "-t", "inner"]) == nil && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        let s = snapshot { s in s.ttys(under: server).count == 2 && s.procs.contains { $0.name == "tmux" && $0.tty != nil } }
        try #require(s.ttys(under: server).count == 2)
        let res = LayerResolver(library: try library(), tmux: TmuxQuery(runner: r, socket: inner), remote: nil)
        let ls = res.resolve(s, terminal: term(server))
        #expect(!ls.contains { $0.kind == .multiplexer })
        #expect(ls.map(\.name) == ["fish", "TestTerm"])
    }
}
