import Foundation
import Darwin
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// Real fish writes history files in temp dirs; the monitor reads them as the app does. The user's history is never read.
@MainActor @Suite(.serialized) struct CoachMonitorTests {
    static let grepID = "coach|suggestion|Count matches with grep -c"

    func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-coach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Has real fish (no config) append `commands` to `<dir>/fish/sktest_history` and returns that URL.
    @discardableResult
    func fishAppend(_ commands: [String], in d: URL) -> URL {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
        let appends = commands.map { "history append \(q($0))" }.joined(separator: "; ")
        _ = ProcessRunner().run("/usr/bin/env", ["XDG_DATA_HOME=\(d.path)", "XDG_CONFIG_HOME=\(d.path)", "/opt/homebrew/bin/fish",
                                                 "--no-config", "-c", "set -g fish_history sktest; \(appends); history save"], timeout: 30)
        return d.appendingPathComponent("fish/sktest_history")
    }

    func config(fish: URL, bash: URL) -> CoachConfig {
        var c = CoachConfig()
        c.fishHistory = fish.path; c.bashHistory = bash.path
        return c
    }

    @Test func monitorPublishesFromRealFiles() async throws {
        let d = try dir()
        let fish = fishAppend(["cat a.log | grep 404 | wc -l"], in: d)
        let m = CoachMonitor(config: config(fish: fish, bash: d.appendingPathComponent("missing_bash_history")))
        await m.refreshNow()
        let a = try #require(m.items.first { $0.id == Self.grepID })
        #expect(a.explain?.contains("seen in 1 command in") == true)
        #expect(a.tags.contains("fish"))
        // a different line for the same detector: when fish rewrites the whole file on save, it keeps only the
        // newest copy of a repeated command, so a second identical line is not always in the file
        fishAppend(["cat b.log | grep 500 | wc -l"], in: d)
        await m.refreshNow()
        let b = try #require(m.items.first { $0.id == Self.grepID })
        #expect(b.explain?.contains("seen in 2 commands") == true)
    }

    @Test func monitorUnchangedFileKeepsGeneration() async throws {
        let d = try dir()
        let fish = fishAppend(["cat a.log | grep 404 | wc -l"], in: d)
        let m = CoachMonitor(config: config(fish: fish, bash: d.appendingPathComponent("missing")))
        await m.refreshNow()
        let g = m.generation
        await m.refreshNow()
        #expect(m.generation == g)
        #expect(!m.items.isEmpty)
    }

    @Test func monitorDisabledPublishesNothing() async throws {
        let d = try dir()
        let fish = fishAppend(["cat a.log | grep 404 | wc -l"], in: d)
        var c = config(fish: fish, bash: d.appendingPathComponent("missing"))
        c.enabled = false
        let m = CoachMonitor(config: c)
        await m.refreshNow()
        #expect(m.items == [])
        #expect(m.recent(shell: .fish, limit: 5).isEmpty)
        // turned on later: the same monitor reads the file; turned off again: the items go
        c.enabled = true
        m.reload(config: c)
        await m.refreshNow()
        #expect(m.items.contains { $0.id == Self.grepID })
        c.enabled = false
        m.reload(config: c)
        await m.refreshNow()
        #expect(m.items == [])
    }

    @Test func recentReturnsShellSpecific() async throws {
        let d = try dir()
        let fish = fishAppend(["echo one", "echo two", "echo three"], in: d)
        let bash = d.appendingPathComponent("bash_history")
        try "ls -la\n#1700000000\ngit status\n".write(to: bash, atomically: true, encoding: .utf8)
        let m = CoachMonitor(config: config(fish: fish, bash: bash))
        await m.refreshNow()
        #expect(m.recent(shell: .bash, limit: 5).map(\.command) == ["ls -la", "git status"])
        #expect(m.recent(shell: .fish, limit: 5).map(\.command) == ["echo one", "echo two", "echo three"])
        #expect(m.recent(shell: .fish, limit: 2).map(\.command) == ["echo two", "echo three"])
    }

    /// The timer only stats the files; with no change there is no parse, no analysis and no new items.
    @Test func idleMonitorUsesLittleCPU() async throws {
        let d = try dir()
        let fish = fishAppend((0..<300).map { "cat f\($0).log | grep 404 | wc -l" }, in: d)
        let m = CoachMonitor(config: config(fish: fish, bash: d.appendingPathComponent("missing")), interval: 0.5)
        await m.refreshNow()
        let g = m.generation
        m.start()
        await pause(0.5)
        let t0 = mainThreadCPU()
        holdMain(3)
        #expect(mainThreadCPU() - t0 < 0.05)   // under ~2% of one core over 3 s, though it ticks every 0.5 s
        #expect(m.generation == g)
        // the timer does tick: a new line shows without a call to refreshNow
        fishAppend(["ls | wc -l"], in: d)
        #expect(await waitUntil { m.generation != g })
        m.stop()
    }

    @Test func dumpHasCountsAndNoCommandText() {
        let c = Coach.analyze(["cat secret-a.log | grep 404 | wc -l", "cat secret-a.log | grep 404 | wc -l", "ls | grep tok"]
            .map { HistoryEntry(command: $0, shell: .bash) })
        let lines = CoachMonitor.dumpLines(c, full: false)
        #expect(lines.contains("bash\tgrep-count\t2"))
        #expect(lines.allSatisfy { $0.split(separator: "\t").count == 3 })
        #expect(!lines.joined().contains("secret") && !lines.joined().contains("tok"))
        #expect(CoachMonitor.dumpLines(c, full: true).joined().contains("secret-a.log"))
    }
}

/// CPU time of the calling thread.
private func mainThreadCPU() -> Double {
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
