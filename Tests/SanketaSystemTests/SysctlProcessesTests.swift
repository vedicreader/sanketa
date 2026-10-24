import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

let tmuxBin = "/opt/homebrew/bin/tmux"

@Suite struct SysctlProcessesTests {
    @Test func snapshotSeesSpawnedChild() throws {
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/bin/sleep")
        c.arguments = ["30"]
        try c.run()
        defer { c.terminate(); c.waitUntilExit() }
        let p = try #require(SysctlProcesses.snapshot().proc(c.processIdentifier))
        #expect(p.name == "sleep")
        #expect(p.ppid == ProcessInfo.processInfo.processIdentifier)
        #expect(p.argv == ["/bin/sleep", "30"])
        #expect(abs(p.start - Date().timeIntervalSince1970) < 5)
    }

    @Test func snapshotTTYOfRealPty() throws {
        let sock = "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-1"
        let r = ProcessRunner()
        defer { _ = r.run(tmuxBin, ["-L", sock, "kill-server"], timeout: 2.0) }
        _ = try #require(r.run(tmuxBin, ["-L", sock, "new", "-d", "-s", "t", "/bin/sleep", "30"], timeout: 3.0))
        let out = try #require(r.run(tmuxBin, ["-L", sock, "display", "-p", "-t", "t", "#{pane_tty} #{pane_pid}"], timeout: 3.0))
        let parts = out.split(whereSeparator: \.isWhitespace).map(String.init)
        try #require(parts.count == 2)
        let tty = parts[0].replacingOccurrences(of: "/dev/", with: "")
        let pid = try #require(Int32(parts[1]))
        let s = SysctlProcesses.snapshot()
        let p = try #require(s.proc(pid))
        #expect(p.tty == tty)
        #expect(s.foreground(tty: tty)?.pid == pid)
    }

    func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }

    @Test func snapshotIsCheap() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let t0 = cpuSeconds()
        var s = ProcessSnapshot([])
        for _ in 0..<10 { s = SysctlProcesses.snapshot(under: [me]) }
        let used = cpuSeconds() - t0
        #expect(s.procs.count > 50)
        #expect(s.proc(me)?.path != nil)
        #expect(used < 0.5, "10 scoped snapshots used \(used) s CPU")
    }

    @Test func subtreeArgvStillCorrect() throws {
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/bin/sleep")
        c.arguments = ["30"]
        try c.run()
        defer { c.terminate(); c.waitUntilExit() }
        let s = SysctlProcesses.snapshot(under: [ProcessInfo.processInfo.processIdentifier])
        let p = try #require(s.proc(c.processIdentifier))
        #expect(p.argv == ["/bin/sleep", "30"])
        #expect(p.path == "/bin/sleep")
        #expect(p.name == "sleep")
        // launchd is outside the subtree: kinfo fields only
        let l = try #require(s.proc(1))
        #expect(l.name == "launchd" && l.tty == nil && l.argv.isEmpty && l.path == nil)
    }
}
