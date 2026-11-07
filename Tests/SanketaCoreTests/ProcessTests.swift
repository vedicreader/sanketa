import Foundation
import Testing
@testable import SanketaCore

func loadSnapshot(_ name: String) throws -> ProcessSnapshot {
    let u = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/snapshots/\(name).json")
    return ProcessSnapshot(try JSONDecoder().decode([ProcInfo].self, from: Data(contentsOf: u)))
}

@Suite struct ProcessTests {
    @Test func ttysUnderTerminal() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        #expect(s.ttys(under: 100) == ["ttys001"])
        #expect(s.children(of: 100).map(\.pid) == [200])
    }

    @Test func foregroundOnTTY() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        #expect(s.foreground(tty: "ttys001")?.pid == 300)
        #expect(s.foreground(tty: "ttys005")?.name == "htop")
        #expect(s.foreground(tty: "ttys999") == nil)
    }

    @Test func chainStopsAtTerminal() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        let htop = try #require(s.proc(600))
        #expect(s.chain(from: htop, until: { $0.pid == 400 }).map(\.name) == ["htop", "fish"])
    }

    @Test func chainSurvivesCycle() {
        func p(_ pid: Int32, _ ppid: Int32) -> ProcInfo {
            ProcInfo(pid: pid, ppid: ppid, pgid: pid, tty: nil, tpgid: 0, name: "x", argv: [], start: 0, path: nil)
        }
        let s = ProcessSnapshot([p(10, 11), p(11, 10)])
        #expect(s.chain(from: s.proc(10)!, until: { _ in false }).map(\.pid) == [10, 11])
    }

    @Test func runnerReturnsStdout() {
        #expect(ProcessRunner().run("/bin/echo", ["hi"], timeout: 1.0) == "hi\n")
    }

    @Test func runnerTimesOut() {
        let t0 = Date()
        #expect(ProcessRunner().run("/bin/sleep", ["5"], timeout: 0.2) == nil)
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }

    /// A background grandchild keeps stdout open after the child exits; the runner gives up instead of racing the reader.
    @Test func runnerPipeHeldByGrandchildIsNil() {
        let t0 = Date()
        #expect(ProcessRunner().run("/bin/sh", ["-c", "/bin/sleep 3 & echo hi"], timeout: 1.0) == nil)
        #expect(Date().timeIntervalSince(t0) < 2.5)
    }

    @Test func runnerNonZeroIsNil() {
        #expect(ProcessRunner().run("/usr/bin/false", [], timeout: 1.0) == nil)
    }

    /// `report` tells why a run gave no output: the exit status with the first line of stderr, no exit, output that
    /// stays open, or a start that failed.
    @Test func runnerReportSaysWhy() {
        let r = ProcessRunner()
        let bad = r.report("/bin/sh", ["-c", "echo first >&2; echo second >&2; exit 3"], timeout: 5.0)
        #expect(bad.out == nil && bad.how.hasPrefix("exit 3 in ") && bad.how.hasSuffix(" ms: first"), "\(bad.how)")
        let ok = r.report("/bin/echo", ["hi"], timeout: 5.0)
        #expect(ok.out == "hi\n" && ok.how.hasPrefix("exit 0 in ") && ok.how.hasSuffix(" ms"), "\(ok.how)")
        let slow = r.report("/bin/sleep", ["5"], timeout: 0.2)
        #expect(slow.out == nil && slow.how == "no exit after 0.2 s", "\(slow.how)")
        let held = r.report("/bin/sh", ["-c", "/bin/sleep 3 & echo hi"], timeout: 5.0)
        #expect(held.out == nil && held.how == "exit 0, output still open after 1 s", "\(held.how)")
        let none = r.report("/nonexistent/tmux", [], timeout: 5.0)
        #expect(none.out == nil && none.how.hasPrefix("did not start: "), "\(none.how)")
    }

    @Test func runnerLargeOutput() {
        let out = ProcessRunner().run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' a"], timeout: 5.0)
        #expect(out?.count == 200000)
    }
}
