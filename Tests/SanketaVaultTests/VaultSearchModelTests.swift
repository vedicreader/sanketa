import AppKit
import Foundation
import Testing
import SanketaCore
@testable import SanketaUI
@testable import SanketaVault

/// Counts its searches. It shows no window; the model opens nothing for real (`open` is a closure).
private final class Counting: VaultSearching, @unchecked Sendable {
    let inner: VaultSearching
    private let lock = NSLock()
    private var queries: [String] = []
    var seen: [String] { lock.withLock { queries } }
    init(_ inner: VaultSearching) { self.inner = inner }
    func search(_ q: String) async -> [SearchItem] {
        lock.withLock { queries.append(q) }
        return await inner.search(q)
    }
}

@MainActor private final class Opened { var urls: [URL] = [] }

@MainActor private func model(_ v: VaultSearching, opened: Opened) -> SearchModel {
    let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")), debounce: 60,
                        vaultDebounce: 0.05, open: { opened.urls.append($0) })
    s.setSource(extra: [SearchItem(packID: "coach", packName: "Better ways", kind: .suggestion, title: "Count sandhi lines",
                                   detail: "grep -c sandhi f")])
    s.setVault(v)
    return s
}

@MainActor private func until(_ seconds: Double, _ cond: () -> Bool) async {
    for _ in 0..<Int(seconds * 50) where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor @Suite(.serialized) struct VaultSearchModelTests {
    @Test func vaultResultsComeAfterPackResultsAndOpenOnReturn() async {
        let opened = Opened()
        let s = model(VaultSearch(path: fixture, abhyasa: abhyasaUp, budget: 5), opened: opened)
        s.query = "sandhi"
        #expect(s.results.map(\.packID) == ["coach"], "pack results show at once")
        await until(3) { s.results.count > 1 }
        #expect(s.results.map(\.packID) == ["coach", "vault:learning", "vault:store"])
        s.move(1)
        #expect(s.activate()?.title == "Vowel sandhi")
        #expect(opened.urls == [URL(string: "http://127.0.0.1:5077/c/vowel-sandhi")!])
    }

    @Test func aResultWithNoTargetShowsAllItsTextOnReturn() async {
        let opened = Opened()
        let s = model(VaultSearch(path: fixture, budget: 5), opened: opened)
        s.query = "sunday plants"
        await until(3) { s.results.contains { $0.title == "Garden reminder" } }
        s.select(s.results.firstIndex { $0.title == "Garden reminder" } ?? -1)
        #expect(s.activate() == nil, "search stays open")
        #expect(s.expanded == s.selected?.id && opened.urls.isEmpty)
        #expect(s.pasteboard.string(forType: .string) == nil, "nothing is copied")
        s.activate()
        #expect(s.expanded == nil, "a second Return makes it short again")
    }

    /// Sanketa alone, Sanketa and the vault, and Sanketa, the vault and abhyasa.
    @Test func threeModes() async throws {
        var c = Config()
        // alone: no vault search, no saving
        c.vault.enabled = false
        #expect(VaultHybrid.make(c.vault, abhyasa: c.abhyasa) == nil)
        // the vault, abhyasa off (the default): a web page opens, a concept shows its text
        c.vault.enabled = true
        c.vault.path = fixture
        c.vault.mcp = false
        let alone = try #require(VaultHybrid.make(c.vault, abhyasa: c.abhyasa))
        #expect((alone.search as? VaultSearch)?.probe == nil, "no abhyasa check at all")
        let opened = Opened()
        let s = model(alone.search, opened: opened)
        s.query = "sandhi"
        await until(3) { s.results.count > 2 }
        s.select(s.results.firstIndex { $0.title == "Vowel sandhi" } ?? -1)
        #expect(s.activate() == nil && s.expanded != nil)
        s.select(s.results.firstIndex { $0.title == "Notes on sandhi" } ?? -1)
        #expect(s.activate()?.title == "Notes on sandhi" && opened.urls == [URL(string: "https://example.com/sandhi")!])
        // the vault and abhyasa: abhyasa makes the links while it answers
        c.abhyasa.enabled = true
        let on = try #require(VaultHybrid.make(c.vault, abhyasa: c.abhyasa))
        #expect((on.search as? VaultSearch)?.probe?.base == URL(string: "http://127.0.0.1:5077"))
        let up = VaultSearch(path: fixture, abhyasa: abhyasaUp, budget: 5)
        #expect(await up.search("sandhi").first?.open == URL(string: "http://127.0.0.1:5077/c/vowel-sandhi"))
        let down = VaultSearch(path: fixture, abhyasa: AbhyasaProbe(base: URL(string: "http://127.0.0.1:5077")!) { _ in false }, budget: 5)
        #expect(await down.search("sandhi").first?.open == nil, "abhyasa does not answer: Return shows the text")
    }

    @Test func keyHints() {
        var i = SearchItem(packID: "vault:ramabana", packName: "ramabana", kind: .vault, title: "t", detail: "d")
        #expect(SearchModel.keyHint(i) == "↩ Show all")
        i.open = URL(string: "http://127.0.0.1:5077/v/ramabana/x")
        i.alt = .resume("x")
        #expect(SearchModel.keyHint(i) == "↩ Open     ⌥↩ Resume session")
        i.alt = .file(URL(fileURLWithPath: "/tmp/MEMORY.md"))
        #expect(SearchModel.keyHint(i) == "↩ Open     ⌥↩ Open file")
        #expect(SearchModel.keyHint(SearchItem(packID: "p", packName: "p", kind: .key, title: "t", detail: "d")) == nil)
    }

    @Test func altReturnResumesASessionOrOpensAFile() async {
        let opened = Opened()
        let s = model(VaultSearch(path: "/nonexistent"), opened: opened)
        var resumed: [String] = []
        s.resume = { resumed.append($0); return true }
        #expect(s.activateAlt() == .none)
        s.setSource(extra: [
            { var i = SearchItem(packID: "vault:ramabana", packName: "ramabana", kind: .vault, title: "Session one", detail: "x"); i.alt = .resume("s1"); return i }(),
            { var i = SearchItem(packID: "vault:ramabana", packName: "ramabana", kind: .vault, title: "Memory one", detail: "x"); i.alt = .file(URL(fileURLWithPath: "/tmp/M.md")); return i }(),
        ])
        s.query = "one"
        s.select(s.results.firstIndex { $0.title == "Session one" } ?? -1)
        #expect(s.activateAlt() == .resumed && resumed == ["s1"])
        s.select(s.results.firstIndex { $0.title == "Memory one" } ?? -1)
        #expect(s.activateAlt() == .opened && opened.urls == [URL(fileURLWithPath: "/tmp/M.md")])
    }

    @Test func shortQueriesAndFastTypingDoNotSearch() async {
        let c = Counting(VaultSearch(path: fixture, budget: 5))
        let s = model(c, opened: Opened())
        s.query = "sa"
        try? await Task.sleep(for: .milliseconds(200))
        #expect(c.seen.isEmpty)
        // each key comes before the debounce ends: only the last query runs
        for q in ["san", "sand", "sandh", "sandhi"] { s.query = q }
        await until(3) { !c.seen.isEmpty }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(c.seen == ["sandhi"])
        // a new query drops the old vault results at once
        s.query = "zzz"
        #expect(!s.results.contains { $0.kind == .vault })
    }

    @Test func noVaultGivesOnlyPackResults() async {
        let s = model(VaultSearch(path: "/nonexistent/vault.db"), opened: Opened())
        s.query = "sandhi"
        try? await Task.sleep(for: .milliseconds(250))
        #expect(s.results.map(\.packID) == ["coach"])
    }
}
