import Testing
import Foundation
@testable import SanketaCore

struct CoachTests {
    func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    @Test func analyzeCountsAndOrders() {
        let es = [
            HistoryEntry(command: "grep x a.log | wc -l", when: at(1), shell: .fish),
            HistoryEntry(command: "grep y b.log | wc -l", when: at(3), shell: .fish),
            HistoryEntry(command: "grep z c.log | wc -l", when: at(2), shell: .fish),
            HistoryEntry(command: "sort n.txt | uniq", when: at(5), shell: .fish),
            HistoryEntry(command: "echo hi", when: at(6), shell: .fish),
        ]
        let cs = Coach.analyze(es)
        #expect(cs.map(\.detectorID) == ["grep-count", "sort-unique"])
        let g = cs[0]
        #expect(g.count == 3 && g.lastSeen == at(3) && g.before == "grep y b.log | wc -l" && g.after == "grep -c y b.log")
        #expect(g.item.kind == .suggestion && g.item.detail == g.after && g.item.packID == "coach" && g.item.packName == "Better ways")
        #expect(g.item.tags == ["coach", "grep-count", "fish"])
        #expect(g.item.explain == "Instead of grep y b.log | wc -l · 3× in your history. grep -c counts matching lines itself.")
    }

    @Test func analyzeSplitsByShell() {
        let line = "grep x a.log | wc -l"
        let cs = Coach.analyze([HistoryEntry(command: line, shell: .fish), HistoryEntry(command: line, shell: .bash)])
        #expect(cs.count == 2)
        #expect(cs[0].item.id == cs[1].item.id)
        #expect(Set(cs.map(\.shell)) == [.fish, .bash])
    }

    @Test func undatedHitsUseLastInFileOrder() {
        let cs = Coach.analyze([HistoryEntry(command: "sort a | uniq", shell: .bash), HistoryEntry(command: "sort b | uniq", shell: .bash)])
        #expect(cs.map(\.before) == ["sort b | uniq"] && cs[0].lastSeen == nil && cs[0].count == 2)
    }

    @Test func oneEntryCountsOnce() {
        let cs = Coach.analyze([HistoryEntry(command: "sort a | uniq; sort b | uniq", shell: .fish)])
        #expect(cs.map(\.count) == [1])
    }

    @Test func analyzeRealFishHistoryFile() throws {
        let lines = [positive[0].input, positive[8].input, positive[24].input, "echo hi"]
        let url = writeFishHistory(lines, in: try tempDir())
        let es = HistoryCache().entries(fish: url, bash: nil, maxEntries: 1000)
        #expect(es.count == 4)
        #expect(Set(Coach.analyze(es).map(\.detectorID)) == ["grep-count", "sort-unique", "math"])
    }

    @Test func analyzeIsFastOnFiveThousandEntries() {
        let es = (0..<5000).map { i in
            let e = positive[i % positive.count]
            // unique lines, so no cached result hides the work
            return HistoryEntry(command: e.input + "; echo \(i)", when: Date(timeIntervalSince1970: TimeInterval(i)), shell: e.shell)
        }
        let start = Date()
        let cs = Coach.analyze(es)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(Set(cs.map(\.detectorID)) == Set(positive.map(\.detector)))
    }
}
