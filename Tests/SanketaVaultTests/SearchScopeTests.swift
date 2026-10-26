import AppKit
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaUI
import SanketaVault

/// Gives `items` for each search and keeps the limits it got. It shows no window.
private final class FixedVault: VaultSearching, @unchecked Sendable {
    let items: [SearchItem]
    private let lock = NSLock()
    private var asked: [Int?] = []
    var limits: [Int?] { lock.withLock { asked } }
    init(_ items: [SearchItem]) { self.items = items }
    func search(_ q: String) async -> [SearchItem] { lock.withLock { asked.append(nil) }; return items }
    func search(_ q: String, limit: Int) async -> [SearchItem] { lock.withLock { asked.append(limit) }; return items }
}

private func doc(_ shelf: String, _ title: String, _ snippet: String = "") -> SearchItem {
    SearchItem(packID: "vault:\(shelf)", packName: shelf, kind: .vault, title: title, detail: snippet)
}

private let packs = [SearchItem(packID: "coach", packName: "Better ways", kind: .suggestion, title: "Count lines",
                                detail: "grep -c sandhi f"),
                     SearchItem(packID: "tmux", packName: "tmux", kind: .key, title: "Vowel sandhi pane", detail: "prefix v")]

@MainActor private func model(_ v: VaultSearching) -> SearchModel {
    let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")), debounce: 60, vaultDebounce: 0.05)
    s.setSource(extra: packs)
    s.setVault(v)
    return s
}

@MainActor private func until(_ seconds: Double, _ cond: () -> Bool) async {
    for _ in 0..<Int(seconds * 50) where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
}

/// The scope of a search (⌘E) and the one ranking in the model.
@MainActor @Suite(.serialized) struct SearchScopeTests {
    @Test func commandECyclesTheScope() {
        let s = model(FixedVault([]))
        #expect(s.scope == .all && s.scope.label == "All")
        s.cycleScope(1)
        #expect(s.scope == .shortcuts && s.scope.label == "Shortcuts")
        s.cycleScope(1)
        #expect(s.scope == .vault && s.scope.label == "Vault")
        s.cycleScope(1)
        #expect(s.scope == .all)
        s.cycleScope(-1)
        #expect(s.scope == .vault, "⇧⌘E goes back")
        s.query = "sandhi"
        s.clear()
        #expect(s.scope == .all, "a new search starts in All")
    }

    @Test func scopeKeys() {
        let e = 14, tab = 48
        #expect(PanelController.scopeKey(keyCode: e, flags: .command, searching: true) == 1)
        #expect(PanelController.scopeKey(keyCode: e, flags: [.command, .shift], searching: true) == -1)
        #expect(PanelController.scopeKey(keyCode: e, flags: [.command, .capsLock], searching: true) == 1)
        #expect(PanelController.scopeKey(keyCode: e, flags: .command, searching: false) == nil, "only in search")
        #expect(PanelController.scopeKey(keyCode: e, flags: [.command, .option], searching: true) == nil)
        #expect(PanelController.scopeKey(keyCode: tab, flags: .command, searching: true) == nil, "Tab stays with the layer list")
        #expect(PanelController.saveKey(keyCode: e, flags: .command, searching: true) == nil)
    }

    @Test func vaultTitleMatchComesFirstInAll() async {
        let s = model(FixedVault([doc("ramabana", "A session", "sandhi"), doc("learning", "Vowel sandhi")]))
        s.query = "vowel sandhi"
        await until(3) { !s.pending }
        #expect(s.results.map(\.title) == ["Vowel sandhi pane", "Vowel sandhi", "A session"])
        s.query = "sandhi"
        await until(3) { !s.pending }
        #expect(s.results.map(\.title) == ["Vowel sandhi pane", "Vowel sandhi", "Count lines", "A session"])
    }

    @Test func eachScopeShowsItsResults() async {
        let v = FixedVault([doc("learning", "Vowel sandhi"), doc("store", "Notes", "sandhi")])
        let s = model(v)
        s.query = "sandhi"
        await until(3) { s.results.contains { $0.kind == .vault } }
        #expect(s.results.count == 4 && v.limits == [nil])
        s.cycleScope(1)
        #expect(s.scope == .shortcuts && s.results.map(\.packID) == ["tmux", "coach"])
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!s.results.contains { $0.kind == .vault } && v.limits == [nil], "no vault search")
        s.cycleScope(1)
        #expect(s.pending, "the list waits for the vault")
        await until(3) { !s.pending }
        #expect(s.results.map(\.title) == ["Vowel sandhi", "Notes"] && v.limits == [nil, SearchModel.vaultWide])
    }

    @Test func vaultScopeAsksForMoreResults() async {
        let k = VaultSearch(path: fixture, budget: 5, )
        #expect(await k.search("sandhi", limit: SearchModel.vaultWide).count >= (await k.search("sandhi")).count)
        // the default of the protocol cuts the plain search
        struct Many: VaultSearching { func search(_ q: String) async -> [SearchItem] { (0..<30).map { doc("store", "N\($0)") } } }
        #expect(await Many().search("x", limit: 20).count == 20)
    }
}
