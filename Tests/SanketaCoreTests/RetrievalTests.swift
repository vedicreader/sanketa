import Testing
import Foundation
@testable import SanketaCore

func entry(_ pack: String, _ title: String, _ detail: String = "", kind: ItemKind = .key) -> SearchItem {
    SearchItem(packID: pack, packName: pack, kind: kind, title: title, detail: detail)
}

@Suite struct RetrievalTests {
    @Test func termsDropStopwordsAndStem() {
        #expect(Retrieval.terms("how do I count matching lines") == ["count", "match", "line"])
        #expect(Retrieval.terms("Splitting the windows") == ["split", "window"])
        #expect(Retrieval.terms("show matches") == ["match"])
    }

    @Test func retrievalFindsSplitForNaturalQuery() {
        let lib = PackLibrary.load(bundled: bundledPacksDir, user: nil)
        let items = lib.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
        let top = Retrieval.candidates("how do I split the window side by side", items, context: ["tmux"]).prefix(10)
        #expect(top.contains { $0.packID == "tmux" && $0.title.lowercased().contains("split") })
    }

    @Test func retrievalKeepsOnlyMatches() {
        let items = [entry("a", "Open file"), entry("b", "Close tab"), entry("c", "Opening files fast")]
        let got = Retrieval.candidates("open files", items, context: ["c"])
        #expect(got.map(\.packID) == ["c", "a"])
    }

    @Test func promptRespectsBudget() {
        let items = (0..<500).map { entry("pk\($0)", "Entry number \($0) " + String(repeating: "x", count: 80),
                                         String(repeating: "k", count: 100)) }
        let (p, refs) = ChoicePrompt.build(task: .search("entry"), candidates: items, maxPicks: 5)
        #expect(p.lines.joined().count <= 6000)
        #expect(p.lines.count > 10)
        #expect(p.refs.count == p.lines.count)
        #expect(Set(refs.keys) == Set(p.refs))
        #expect(p.lines.allSatisfy { $0.count <= 160 })
        #expect(refs["e1"] == items[0])
    }

    @Test func promptGivesOneRefPerItem() {
        let a = entry("p", "A"), b = entry("p", "B")
        let (p, refs) = ChoicePrompt.build(task: .search("x"), candidates: [a, a, b, a], maxPicks: 2)
        #expect(p.refs == ["e1", "e2"])
        #expect(refs == ["e1": a, "e2": b])
    }

    @Test func promptCopyIsExact() {
        let it = entry("tmux", "Split pane left/right", "prefix %")
        let (p, _) = ChoicePrompt.build(task: .search("split pane"), candidates: [it], maxPicks: 3)
        #expect(p.userText == "Request: split pane\nEntries:\ne1 | tmux | Split pane left/right | prefix %\nAnswer with JSON only: {\"picks\": [...]}, where picks is a list of ref strings from the Entries list.")
        #expect(p.instructions == "You match a request to entries from a list of keyboard shortcuts and command tips. Answer only with refs from the list, best first, at most 3. Return an empty list if nothing fits.")
    }

    @Test func suggestPromptKeepsLastTenCommands() {
        let cmds = (1...15).map { "cmd\($0) " + String(repeating: "a", count: 200) }
        let (p, _) = ChoicePrompt.build(task: .suggest(cmds), candidates: [entry("git", "Status", "git status")], maxPicks: 2)
        guard case .suggest(let kept) = p.task else { Issue.record("not suggest"); return }
        #expect(kept.count == 10)
        #expect(kept.first?.hasPrefix("cmd6 ") == true)
        #expect(kept.allSatisfy { $0.count == 120 })
        #expect(p.userText.hasPrefix("Recent commands:\n" + kept.joined(separator: "\n") + "\nPick entries that would help with what these commands do.\nEntries:\ne1 | git | Status | git status\n"))
        #expect(p.userText.hasSuffix("\nAnswer with JSON only: {\"picks\": [...]}, where picks is a list of ref strings from the Entries list."))
    }

    @Test func halvedKeepsFirstHalf() {
        let items = (0..<9).map { entry("p", "T\($0)") }
        let (p, _) = ChoicePrompt.build(task: .search("t"), candidates: items, maxPicks: 2)
        let h = p.halved()
        #expect(h.refs == ["e1", "e2", "e3", "e4"])
        #expect(h.lines == Array(p.lines.prefix(4)))
        #expect(h.halved().halved().halved().refs == ["e1"])
    }

    @Test func groundingDropsInventedRefs() {
        let items = (1...5).map { entry("p", "T\($0)") }
        let refs = Dictionary(uniqueKeysWithValues: items.enumerated().map { ("e\($0.offset + 1)", $0.element) })
        let order = (1...5).map { "e\($0)" }
        #expect(Grounding.resolve(["e3", "e99", "bogus", "e3", "e1"], refs, order: order, max: 5) == [items[2], items[0]])
        #expect(Grounding.resolve(["e3", "e1", "e2"], refs, order: order, max: 2) == [items[2], items[0]])
    }

    @Test func groundingRejectsPositionalCollapse() {
        let items = (1...10).map { entry("p", "T\($0)") }
        let order = (1...10).map { "e\($0)" }
        let refs = Dictionary(uniqueKeysWithValues: zip(order, items).map { ($0, $1) })
        #expect(Grounding.resolve(["e1", "e2", "e3"], refs, order: order, max: 5) == [])
        #expect(Grounding.resolve(["e1"], refs, order: order, max: 5) == [items[0]])
        #expect(Grounding.resolve(["e1", "e3"], refs, order: order, max: 5) == [items[0], items[2]])
        #expect(Grounding.resolve(["e1", "e2", "e2"], refs, order: order, max: 5) == [])
        #expect(Grounding.resolve(["e1", "e2", "bogus"], refs, order: order, max: 5) == [])
        #expect(Grounding.resolve(["bogus", "e1", "e1"], refs, order: order, max: 5) == [items[0]])
    }
}
