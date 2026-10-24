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
}
