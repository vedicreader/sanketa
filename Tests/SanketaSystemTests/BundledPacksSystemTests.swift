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

    func tmux(_ sock: String, _ args: [String]) -> String? { r.run(tmuxBin, ["-L", sock] + args, timeout: 3.0) }

    func library() throws -> PackLibrary {
        let lib = PackLibrary.load(bundled: Self.packs, user: nil)
        try #require(lib.errors.isEmpty && lib.packs.count >= 17, "\(lib.errors)")
        return lib
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
    @Test func bundledTmuxKeysAreRealDefaults() throws {
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
    @Test func bundledPacksActivateForRealProcesses() throws {
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
        let end = Date().addingTimeInterval(5)
        while tmux(inner, ["has-session", "-t", "inner"]) == nil && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        _ = try #require(tmux(inner, ["send-keys", "-t", "inner", "/opt/homebrew/bin/htop", "Enter"]))
        let pane = try #require(tmux(inner, ["display", "-p", "-t", "inner", "#{pane_tty}"]))
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
        let s = snapshot { $0.foreground(tty: pane)?.name == "htop" }
        let res = LayerResolver(library: lib, tmux: TmuxQuery(runner: r, socket: inner), remote: nil)
        let ls = res.resolve(s, terminal: TerminalContext(pid: server, bundleID: "test.terminal", appName: "TestTerm", windowTitle: nil))
        #expect(ls.map(\.name) == ["htop", "fish", "tmux", "TestTerm"])
        #expect(ls.map(\.packID) == ["htop", "fish", "tmux", "app:test.terminal"])

        _ = try #require(tmux(plain, ["-f", "/dev/null", "new", "-d", "-s", "v", "/opt/homebrew/bin/nvim", "--clean", "-n"]))
        let vpid = try #require(tmux(plain, ["display", "-p", "-t", "v", "#{pane_pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let nvs = snapshot { $0.proc(vpid)?.name == "nvim" }
        let nv = try #require(nvs.proc(vpid))
        #expect(res.layer(nv.name, argv: nv.argv).packID == "vim")
    }

    /// Claude Code as installed natively: the executable is `…/claude/versions/<version>` and argv[0] is `claude`
    /// (reproduced with `exec -a`); plus a `python3 …/bin/ramabana` script.
    @Test func argvAndNameMatchRealSpawnedProcesses() throws {
        let lib = try library()
        let res = LayerResolver(library: lib, tmux: TmuxQuery(runner: r, socket: plain), remote: nil)
        let d = try tempDir()
        let versions = d.appendingPathComponent("claude/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let exe = versions.appendingPathComponent("2.1.999")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: exe.path)
        // a copied platform binary is killed at exec; an ad-hoc signature makes it runnable
        _ = try #require(r.run("/usr/bin/codesign", ["--force", "-s", "-", exe.path], timeout: 5.0))
        let c = try spawn("/bin/bash", ["-c", "exec -a claude \(exe.path) 30"])
        defer { c.terminate(); c.waitUntilExit() }
        // SysctlProcesses caches argv per (pid, start), which exec keeps; snapshot only after bash has exec'd
        let end = Date().addingTimeInterval(5)
        while !(r.run("/bin/ps", ["-o", "args=", "-p", "\(c.processIdentifier)"])?.hasPrefix("claude ") ?? false) && Date() < end {
            Thread.sleep(forTimeInterval: 0.05)
        }
        let cps = snapshot { $0.proc(c.processIdentifier)?.name == "2.1.999" }
        let cp = try #require(cps.proc(c.processIdentifier))
        try #require(cp.argv.first == "claude")
        #expect(res.layer(cp.name, argv: cp.argv) == Layer(kind: .program, name: "claude", packID: "claude"))

        let bin = d.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("ramabana")
        try "import time\ntime.sleep(30)\n".write(to: script, atomically: true, encoding: .utf8)
        let py = try spawn("/usr/bin/python3", [script.path, "--resume"])
        defer { py.terminate(); py.waitUntilExit() }
        let pps = snapshot { $0.proc(py.processIdentifier)?.argv.contains(script.path) ?? false }
        let pp = try #require(pps.proc(py.processIdentifier))
        try #require(!pp.name.contains("ramabana"))     // matched by argv, not by name
        #expect(res.layer(pp.name, argv: pp.argv) == Layer(kind: .program, name: "ramabana", packID: "ramabana"))
    }

    /// ramabana runs its own tmux server whose argv names the script, so that client resolves to ramabana, not tmux.
    @Test func ramabanaPrivateTmuxResolvesToRamabana() throws {
        defer { _ = tmux(plain, ["kill-server"]) }
        let lib = try library()
        let script = try tempDir().appendingPathComponent("bin/ramabana").path
        _ = try #require(tmux(plain, ["-f", "/dev/null", "new", "-d", "-s", "r", "sh", "-c", "sleep 30", "ramabana", script]))
        let spid = try #require(tmux(plain, ["display", "-p", "-t", "r", "#{pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let sps = snapshot { $0.proc(spid)?.argv.contains(script) ?? false }
        let sp = try #require(sps.proc(spid))
        #expect(sp.name == "tmux")
        #expect(lib.pack(process: sp.name, argv: sp.argv)?.id == "ramabana")
        #expect(lib.pack(process: "tmux", argv: ["tmux", "-L", "work", "attach"])?.id == "tmux")
    }
}
