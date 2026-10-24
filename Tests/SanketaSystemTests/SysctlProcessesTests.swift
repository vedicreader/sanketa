import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

let tmuxBin = "/opt/homebrew/bin/tmux"

/// CPU time of the calling thread (`thread_info`), not of the whole test process.
func threadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, port) }
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    return Double(info.user_time.seconds + info.system_time.seconds)
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
}

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

    /// A child snapshotted between fork and exec must not keep the parent's path and argv after the exec.
    @Test func execRefreshesCachedDetails() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let c = Process()
        c.executableURL = URL(fileURLWithPath: "/bin/sh")
        c.arguments = ["-c", "sleep 0.3; exec /bin/sleep 30"]
        try c.run()
        defer { c.terminate(); c.waitUntilExit() }
        let before = try #require(SysctlProcesses.snapshot(under: [me]).proc(c.processIdentifier))
        #expect(before.name == "sh" && before.argv.first == "/bin/sh", "\(before)")
        var after = before
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.1)
            after = try #require(SysctlProcesses.snapshot(under: [me]).proc(c.processIdentifier))
            if after.name == "sleep" { break }
        }
        #expect(after.start == before.start)
        #expect(after.name == "sleep")
        #expect(after.argv == ["/bin/sleep", "30"])
        #expect(after.path == "/bin/sleep")
    }

    /// CPU of the calling thread only, so suites running in parallel in this process don't count.
    @Test func snapshotIsCheap() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let t0 = threadCPUSeconds()
        var s = ProcessSnapshot([])
        for _ in 0..<10 { s = SysctlProcesses.snapshot(under: [me]) }
        let used = threadCPUSeconds() - t0
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
