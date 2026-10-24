import Testing
import Foundation
@testable import SanketaCore

struct HistoryTests {
    func parseFish(_ u: URL) -> [HistoryEntry] { FishHistory.parse(HistoryFile.readTail(u) ?? "") }

    @Test func fishParsesRealFishOutput() throws {
        let cmds = ["cat a.log | grep 404 | wc -l", "for f in (ls *.txt)\necho $f\nend", "echo a\\b"]
        let es = parseFish(writeFishHistory(cmds, in: try tempDir()))
        #expect(es.map(\.command) == cmds)
        #expect(es.allSatisfy { $0.shell == .fish && abs(($0.when ?? .distantPast).timeIntervalSinceNow) < 120 })
    }

    @Test func fishIgnoresPathsAndAddedWhen() {
        let es = FishHistory.parse("junk\n- cmd: ls\n  when: 1792000000\n  paths:\n    - /tmp\n  added_when: 1792000001\n- cmd: pwd\n  when: 1792000002\n")
        #expect(es.map(\.command) == ["ls", "pwd"])
        #expect(es[0].when == Date(timeIntervalSince1970: 1792000000))
    }

    @Test func bashParsesRealBashOutput() throws {
        let dir = try tempDir()
        _ = runBash("set -o history; history -s 'sort x | uniq'; history -s 'ps aux | grep node'; history -w h", in: dir)
        let es = BashHistory.parse(HistoryFile.readTail(dir.appendingPathComponent("h")) ?? "")
        #expect(es.map(\.command) == ["sort x | uniq", "ps aux | grep node"])
        #expect(es.allSatisfy { $0.when == nil && $0.shell == .bash })
    }

    @Test func bashTimestampsApply() {
        let es = BashHistory.parse("#1792000000\nls -la\npwd\n")
        #expect(es.map(\.command) == ["ls -la", "pwd"])
        #expect(es[0].when == Date(timeIntervalSince1970: 1792000000) && es[1].when == nil)
    }

    @Test func missingFilesGiveEmpty() throws {
        let dir = try tempDir()
        #expect(HistoryCache().entries(fish: dir.appendingPathComponent("nope"), bash: dir.appendingPathComponent("nope2"), maxEntries: 10) == [])
        #expect(HistoryFile.readTail(dir.appendingPathComponent("nope")) == nil)
    }

    @Test func readsTailOfHugeFile() throws {
        let u = try tempDir().appendingPathComponent("big")
        var s = ""
        s.reserveCapacity(21_000_000)
        var n = 0
        while s.utf8.count < 20_000_000 { s += "- cmd: echo \(n)\n  when: \(n)\n"; n += 1 }
        try s.write(to: u, atomically: true, encoding: .utf8)
        let t0 = Date()
        let text = try #require(HistoryFile.readTail(u))
        let es = FishHistory.parse(text)
        #expect(text.utf8.count <= 4_000_000)
        #expect(es.first?.command.range(of: "^echo \\d+$", options: .regularExpression) != nil)
        #expect(es.last?.command == "echo \(n - 1)")
        #expect(Date().timeIntervalSince(t0) < 5)
    }

    @Test func invalidUTF8DoesNotCrash() throws {
        let u = try tempDir().appendingPathComponent("h")
        var d = Data("- cmd: ls ".utf8)
        d.append(contentsOf: [0xFF, 0xFE])
        d.append(Data("\n  when: 1\n- cmd: pwd\n  when: 2\n".utf8))
        try d.write(to: u)
        let es = parseFish(u)
        #expect(es.count == 2 && es[1].command == "pwd")
    }

    @Test func truncatedLastEntryKept() {
        let es = FishHistory.parse("- cmd: ls\n  when: 1\n- cmd: git st")
        #expect(es.last?.command == "git st" && es.last?.when == nil)
    }

    @Test func cacheReReadsOnlyOnChange() throws {
        let dir = try tempDir()
        let u = writeFishHistory(["ls"], in: dir)
        let c = HistoryCache()
        #expect(c.entries(fish: u, bash: nil, maxEntries: 100).map(\.command) == ["ls"])
        let g = c.generation
        _ = c.entries(fish: u, bash: nil, maxEntries: 100)
        #expect(c.generation == g)
        writeFishHistory(["git status"], in: dir)
        let es = c.entries(fish: u, bash: nil, maxEntries: 100)
        #expect(c.generation == g + 1 && es.last?.command == "git status")
    }

    @Test func maxEntriesKeepsNewest() throws {
        let cmds = (0..<10).map { "cmd\($0)" }
        let u = writeFishHistory(cmds, in: try tempDir())
        #expect(HistoryCache().entries(fish: u, bash: nil, maxEntries: 3).map(\.command) == ["cmd7", "cmd8", "cmd9"])
    }
}
