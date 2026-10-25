import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// A tmux client on a private server (`-L name`, as ramabana runs it). Nothing gives the resolver or the engine
/// the socket: they must read it from the client's argv. An outer private tmux server stands in for the terminal app.
@Suite(.serialized) struct PrivateSocketSystemTests {
    let r = ProcessRunner()
    let me = ProcessInfo.processInfo.processIdentifier
    var outer: String { "sanketa-test-\(me)-ps-outer" }
    var inner: String { "sanketa-test-\(me)-ps-x" }
    static let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")

    func tmux(_ sock: String, _ args: [String]) -> String? { r.run(tmuxBin, ["-L", sock] + args, timeout: 3.0) }
    func trimmed(_ s: String?) -> String? { s?.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Starts the outer server with fish, types `tmux -L inner -f conf new -s inner <cmd>` into it and waits for the
    /// inner pane's foreground process `fg`. `cmd` has more than one word, so tmux runs it with no shell. Returns the outer server pid (the "terminal").
    func start(innerCommand cmd: String, conf: URL, fg: String) async throws -> Int32 {
        _ = try #require(tmux(outer, ["-f", "/dev/null", "new", "-d", "-s", "outer", "-x", "200", "-y", "50",
                                      "/opt/homebrew/bin/fish", "--no-config"]))
        let server = try #require(trimmed(tmux(outer, ["display", "-p", "-t", "outer", "#{pid}"])).flatMap { Int32($0) })
        _ = try #require(tmux(outer, ["send-keys", "-t", "outer",
            "set -gx SHELL /opt/homebrew/bin/fish; \(tmuxBin) -L \(inner) -f \(conf.path) new -s inner \(cmd)", "Enter"]))
        await waitUntil { tmux(inner, ["has-session", "-t", "inner"]) != nil }
        let pane = try #require(trimmed(tmux(inner, ["display", "-p", "-t", "inner", "#{pane_tty}"])))
            .replacingOccurrences(of: "/dev/", with: "")
        await waitUntil { SysctlProcesses.snapshot().foreground(tty: pane)?.name == fg }
        try #require(SysctlProcesses.snapshot().foreground(tty: pane)?.name == fg)
        return server
    }

    func conf() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("tmux.conf")
        // a binding that only the private server has
        try "bind-key M-F12 display-message sanketa-private\n".write(to: f, atomically: true, encoding: .utf8)
        return f
    }

    @Test func clientArgvNamesTheServer() {
        #expect(TmuxArgs.server(["tmux", "-L", "ramabana-6a36be8b", "-f", "/x/tmux.conf", "new", "-A"]) == ["-L", "ramabana-6a36be8b"])
        #expect(TmuxArgs.server(["tmux", "-Lwork", "attach"]) == ["-L", "work"])
        #expect(TmuxArgs.server(["tmux", "-S", "/tmp/s", "-L", "x", "attach"]) == ["-S", "/tmp/s"])
        #expect(TmuxArgs.server(["tmux", "-2u", "-f", "/dev/null", "new"]) == [])
        #expect(TmuxArgs.server(["tmux", "new", "-L", "not-an-option"]) == [])
        #expect(TmuxArgs.server(["tmux"]) == [])
    }

    /// htop in a pane of a private server: the resolver finds the pane through the client's `-L` argument.
    @Test func resolverFindsPaneThroughClientArgv() async throws {
        defer { _ = tmux(inner, ["kill-server"]); _ = tmux(outer, ["kill-server"]) }
        let server = try await start(innerCommand: "/opt/homebrew/bin/htop -d 50", conf: try conf(), fg: "htop")
        let lib = PackLibrary.load(bundled: Self.packs, user: nil)
        let res = LayerResolver(library: lib, tmux: TmuxQuery(runner: r), remote: nil)
        let ls = res.resolve(SysctlProcesses.snapshot(), terminal: TerminalContext(pid: server, bundleID: "test.terminal",
                                                                                   appName: "TestTerm", windowTitle: nil))
        #expect(ls.map(\.name) == ["htop", "tmux", "fish", "TestTerm"])
        #expect(ls.map(\.packID) == ["htop", "tmux", "fish", "app:test.terminal"])
    }

    /// The engine, with no socket set, shows the pane and takes the live keys from the private server's config.
    @Test func engineLiveKeysComeFromThePrivateServer() async throws {
        defer { _ = tmux(inner, ["kill-server"]); _ = tmux(outer, ["kill-server"]) }
        let server = try await start(innerCommand: "/opt/homebrew/bin/htop -d 50", conf: try conf(), fg: "htop")
        var config = Config()
        config.terminals = ["test.terminal"]
        let c = ContextEngine(config: config, library: PackLibrary.load(bundled: Self.packs, user: nil))
            .compute(pid: server, bundleID: "test.terminal", appName: "TestTerm")
        #expect(c.layers.map(\.name) == ["htop", "tmux", "fish", "TestTerm"])
        let t = try #require(c.packs.first { $0.id == "tmux" })
        #expect(t.keys.contains { $0.keys == "prefix M-F12" && $0.command == "display-message sanketa-private" })
        #expect(t.keys.contains { $0.action == "Split pane left/right" })
    }

    /// ramabana's shape: a private server whose argv names bin/ramabana. The pane's layer is ramabana; the client's
    /// tmux layer has the same pack, so it shows once.
    @Test func ramabanaPaneShowsAboveItsTmux() async throws {
        defer { _ = tmux(inner, ["kill-server"]); _ = tmux(outer, ["kill-server"]) }
        let script = try conf().deletingLastPathComponent().appendingPathComponent("bin/ramabana").path
        // `; :` keeps sh alive (no exec of sleep), as ramabana's script keeps its interpreter alive
        let server = try await start(innerCommand: "sh -c 'sleep 30; :' ramabana \(script)", conf: try conf(), fg: "bash")
        var config = Config()
        config.terminals = ["test.terminal"]
        let c = ContextEngine(config: config, library: PackLibrary.load(bundled: Self.packs, user: nil))
            .compute(pid: server, bundleID: "test.terminal", appName: "TestTerm")
        // macOS /bin/sh is bash; it runs ramabana, so the crumb says ramabana
        #expect(c.layers.map(\.name) == ["ramabana", "fish", "TestTerm"])
        #expect(c.layers.map(\.packID) == ["ramabana", "fish", "app:test.terminal"])
        #expect(c.packs.first?.id == "ramabana")
    }
}
