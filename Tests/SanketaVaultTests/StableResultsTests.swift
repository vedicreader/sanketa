import AppKit
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaUI
import SanketaVault

private struct Fixed: VaultSearching {
    let items: [SearchItem]
    func search(_ q: String) async -> [SearchItem] { items }
}

private func doc(_ shelf: String, _ title: String, _ snippet: String = "") -> SearchItem {
    SearchItem(packID: "vault:\(shelf)", packName: shelf, kind: .vault, title: title, detail: snippet)
}

/// Ten keys that match "sandhi rule" as a phrase (band 3): a vault title with each word (band 4) ranks above them.
private let keys = (0..<10).map { SearchItem(packID: "p", packName: "p", kind: .key, title: "Xsandhi rule \($0)", detail: "x", command: "c\($0)") }

@MainActor private func model(_ first: [SearchItem], _ extra: [SearchItem] = keys) -> SearchModel {
    let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")), debounce: 60, vaultDebounce: 0.05)
    s.setSource(extra: extra)
    s.setVault(Fixed(items: first))
    return s
}

@MainActor private func until(_ seconds: Double, _ cond: () -> Bool) async {
    for _ in 0..<Int(seconds * 50) where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
}

/// Rows that show keep their place for the query; late results come below them. Only a new query ranks again.
@MainActor @Suite(.serialized) struct StableResultsTests {
    @Test func firstListWaitsForTheVaultAndUsesOneRanking() async {
        let s = model([doc("learning", "Sandhi rule book", "old")])
        s.query = "sandhi rule"
        #expect(s.pending && s.results.isEmpty)
        await until(3) { !s.pending }
        #expect(s.results.first?.title == "Sandhi rule book" && s.results.count == 11)
    }

    @Test func hybridResultsAfterKeywordResultsDoNotMoveVisibleRows() async {
        let s = model([doc("learning", "Sandhi rule book", "old")])
        s.query = "sandhi rule"
        await until(3) { !s.pending }
        let before = s.results.map(\.id)
        // the hybrid answer: the same document with new text, and a new document that ranks above the keys
        s.arrive(vault: [doc("store", "Sandhi rule notes", "x"), doc("learning", "Sandhi rule book", "new")])
        #expect(Array(s.results.map(\.id).prefix(SearchModel.visibleRows)) == Array(before.prefix(SearchModel.visibleRows)))
        #expect(s.results[0].detail == "new", "the same document changes in its place")
        #expect(s.results.filter { $0.title == "Sandhi rule book" }.count == 1)
        #expect(s.results[SearchModel.visibleRows].title == "Sandhi rule notes", "just below the rows that show")
        #expect(s.results.count == 12 && Set(before).isSubset(of: Set(s.results.map(\.id))))
    }

    @Test func theSelectedRowStaysWhereItIs() async {
        let s = model([])
        s.query = "sandhi rule"
        await until(3) { !s.pending }
        s.move(9)
        let sel = s.selected?.id
        s.arrive(vault: [doc("store", "Sandhi rule notes")])
        #expect(s.selection == 9 && s.selected?.id == sel)
        #expect(s.results[10].title == "Sandhi rule notes", "below the selected row")
    }

    @Test func latePicksDoNotMoveVisibleRows() async {
        let few = Array(keys.prefix(3))
        let s = model([], few)
        s.query = "sandhi rule"
        await until(3) { !s.pending }
        s.move(1)
        let before = s.results.map(\.id), sel = s.selected?.id
        let pick = SearchItem(packID: "q", packName: "q", kind: .tip, title: "How rules join", detail: "y")
        s.apply(SmartResult(items: [pick] + few.reversed(), picked: [pick.id, few[2].id]))
        #expect(Array(s.results.map(\.id).prefix(3)) == before, "the rows stay in their order")
        #expect(s.results.last == pick && s.picked.contains(few[2].id))
        #expect(s.selection == 1 && s.selected?.id == sel)
        // a new query ranks again, with no picks
        s.query = "xsandhi rule 2"
        await until(3) { !s.pending }
        #expect(s.results.map(\.id) == [few[2].id] && s.picked.isEmpty && s.selection == 0)
    }

    @Test func returnBeforeTheVaultAnswersActsOnTheNewList() async {
        let s = model([doc("learning", "Sandhi rule book")])
        s.query = "xsandhi rule 4"
        #expect(s.pending)
        #expect(s.activate()?.title == "Xsandhi rule 4" && !s.pending)
    }
}
