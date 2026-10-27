import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// The real bundled packs against real processes: private tmux servers, spawned programs, sysctl snapshots.
@Suite(.serialized) struct BundledPacksSystemTests {
    let r = ProcessRunner()
    let pid = ProcessInfo.processInfo.processIdentifier
    var outer: String { "sanketa-test-\(pid)-bp-outer" }
    var inner: String { "sanketa-test-\(pid)-bp-inner" }
    var plain: String { "sanketa-test-\(pid)-bp-plain" }
    static let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")

    func tmux(_ sock: String, _ args: [String]) -> String? { r.run(tmuxBin, ["-L", sock] + args, timeout: 15.0) }   // 15 s: room for a busy Mac

    func library() throws -> PackLibrary {
        let lib = PackLibrary.load(bundled: Self.packs, user: nil)
        try #require(lib.errors.isEmpty && lib.packs.count >= 17, "\(lib.errors)")
        return lib
    }

    func snapshot(until ok: (ProcessSnapshot) -> Bool) async -> ProcessSnapshot {
        var s = ProcessSnapshot([])
        await waitUntil { s = SysctlProcesses.snapshot(); return ok(s) }
        return s
    }

    func spawn(_ bin: String, _ args: [String]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        return p
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Every bundled tmux key is a default binding of a real tmux 3.x server with no config, so live merge keeps its label.
    @Test func bundledTmuxKeysAreRealDefaults() async throws {
        defer { _ = tmux(plain, ["kill-server"]) }
        _ = try #require(tmux(plain, ["-f", "/dev/null", "new", "-d", "-s", "p"]))
        let live = Tmux.parseKeys(try #require(tmux(plain, ["list-keys"])))
        let pack = try #require(try library().packs["tmux"])
        let liveSet = Set(live.map { "\($0.keys)\t\($0.command ?? "")" })
        for k in pack.keys { #expect(liveSet.contains("\(k.keys)\t\(k.command ?? "")"), "not a live default: \(k.keys) \(k.command ?? "")") }
        let merged = Tmux.mergeLive(pack, live: live)
        for k in pack.keys { #expect(merged.keys.contains { $0.keys == k.keys && $0.action == k.action }, "\(k.action) lost in merge") }
    }

    /// fish → inner tmux → htop, as a real nested pane, resolves to the bundled pack ids; nvim in a pane maps to vim.
    @Test func bundledPacksActivateForRealProcesses() async throws {
        defer {
            _ = tmux(inner, ["kill-server"])
            _ = tmux(outer, ["kill-server"])
            _ = tmux(plain, ["kill-server"])
        }
        let lib = try library()
        _ = try #require(tmux(outer, ["-f", "/dev/null", "new", "-d", "-s", "outer", "-x", "200", "-y", "50",
                                      "/opt/homebrew/bin/fish", "--no-config"]))
        let server = try #require(tmux(outer, ["display", "-p", "-t", "outer", "#{pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        _ = try #require(tmux(outer, ["send-keys", "-t", "outer",
            "set -gx SHELL /opt/homebrew/bin/fish; /opt/homebrew/bin/tmux -L \(inner) -f /dev/null new -s inner", "Enter"]))
        await waitUntil { tmux(inner, ["has-session", "-t", "inner"]) != nil }
        _ = try #require(tmux(inner, ["send-keys", "-t", "inner", "/opt/homebrew/bin/htop", "Enter"]))
        let pane = try #require(tmux(inner, ["display", "-p", "-t", "inner", "#{pane_tty}"]))
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
        let s = await snapshot { $0.foreground(tty: pane)?.name == "htop" }
        let res = LayerResolver(library: lib, tmux: TmuxQuery(runner: r, socket: inner), remote: nil)
        let ls = res.resolve(s, terminal: TerminalContext(pid: server, bundleID: "test.terminal", appName: "TestTerm", windowTitle: nil))
        #expect(ls.map(\.name) == ["htop", "fish", "tmux", "TestTerm"])
        #expect(ls.map(\.packID) == ["htop", "fish", "tmux", "app:test.terminal"])

        _ = try #require(tmux(plain, ["-f", "/dev/null", "new", "-d", "-s", "v", "/opt/homebrew/bin/nvim", "--clean", "-n"]))
        let vpid = try #require(tmux(plain, ["display", "-p", "-t", "v", "#{pane_pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let nvs = await snapshot { $0.proc(vpid)?.name == "nvim" }
        let nv = try #require(nvs.proc(vpid))
        #expect(res.layer(nv.name, argv: nv.argv).packID == "vim")
    }

    /// Claude Code as installed natively: the executable is `…/claude/versions/<version>` and argv[0] is `claude`.
    /// Described as data, not spawned: copying, re-signing and argv[0]-spoofing a binary trips the endpoint threat detector.
    /// Plus a real `python3 …/bin/ramabana` script.
    @Test func argvAndNameMatchRealSpawnedProcesses() async throws {
        let lib = try library()
        let res = LayerResolver(library: lib, tmux: TmuxQuery(runner: r, socket: plain), remote: nil)
        let d = try tempDir()
        let cp = ProcInfo(pid: 4242, ppid: 1, pgid: 4242, tty: "ttys009", tpgid: 4242, name: "2.1.999",
                          argv: ["claude"], start: 0, path: NSHomeDirectory() + "/.local/share/claude/versions/2.1.999")
        #expect(res.layer(cp.name, argv: cp.argv) == Layer(kind: .program, name: "claude", packID: "claude"))

        let bin = d.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("ramabana")
        try "import time\ntime.sleep(30)\n".write(to: script, atomically: true, encoding: .utf8)
        let py = try spawn("/usr/bin/python3", [script.path, "--resume"])
        defer { py.terminate(); py.waitUntilExit() }
        let pps = await snapshot { $0.proc(py.processIdentifier)?.argv.contains(script.path) ?? false }
        let pp = try #require(pps.proc(py.processIdentifier))
        try #require(!pp.name.contains("ramabana"))     // matched by argv, not by name
        #expect(res.layer(pp.name, argv: pp.argv) == Layer(kind: .program, name: "ramabana", packID: "ramabana"))
    }

    /// ramabana runs its own tmux server whose argv names the script, so that client resolves to ramabana, not tmux.
    @Test func ramabanaPrivateTmuxResolvesToRamabana() async throws {
        defer { _ = tmux(plain, ["kill-server"]) }
        let lib = try library()
        let script = try tempDir().appendingPathComponent("bin/ramabana").path
        _ = try #require(tmux(plain, ["-f", "/dev/null", "new", "-d", "-s", "r", "sh", "-c", "sleep 30", "ramabana", script]))
        let spid = try #require(tmux(plain, ["display", "-p", "-t", "r", "#{pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let sps = await snapshot { $0.proc(spid)?.argv.contains(script) ?? false }
        let sp = try #require(sps.proc(spid))
        #expect(sp.name == "tmux")
        #expect(lib.pack(process: sp.name, argv: sp.argv)?.id == "ramabana")
        #expect(lib.pack(process: "tmux", argv: ["tmux", "-L", "work", "attach"])?.id == "tmux")
    }
}
