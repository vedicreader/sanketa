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
    @Test func vaultResultsJoinTheRankingAndOpenOnReturn() async {
        let opened = Opened()
        let s = model(VaultSearch(path: fixture, abhyasa: abhyasaUp, budget: 5), opened: opened)
        s.query = "sandhi"
        #expect(s.pending && s.results.isEmpty, "the first list waits for the vault")
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
        // the vault, abhyasa turned off: a web page opens, a concept shows its text
        c.vault.enabled = true
        c.vault.path = fixture
        c.vault.mcp = false
        c.abhyasa.enabled = false
        let alone = try #require(VaultHybrid.make(c.vault, abhyasa: c.abhyasa))
        #expect((alone.search as? VaultSearch)?.probe == nil, "no abhyasa check at all")
        let opened = Opened()
        let s = model(try #require(alone.search), opened: opened)
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
        // no vault file: no vault search
        c.vault.path = "/nonexistent/vault.db"
        #expect(VaultHybrid.make(c.vault, abhyasa: c.abhyasa) == nil)
        // no vault file but a server: no search, but a note can be saved, which makes the file
        c.vault.mcp = true
        c.vault.mcpURL = "http://127.0.0.1:9/mcp"
        let writeOnly = try #require(VaultHybrid.make(c.vault, abhyasa: c.abhyasa))
        #expect(writeOnly.search == nil && writeOnly.writer is VaultHybrid)
        (writeOnly.writer as? VaultHybrid)?.client.close()
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
        await until(3) { !s.pending }
        s.select(s.results.firstIndex { $0.title == "Session one" } ?? -1)
        #expect(s.activateAlt() == .resumed && resumed == ["s1"])
        s.select(s.results.firstIndex { $0.title == "Memory one" } ?? -1)
        #expect(s.activateAlt() == .opened && opened.urls == [URL(fileURLWithPath: "/tmp/M.md")])
    }

    /// ⌥Return on a note with no page and no file: its text goes to a Markdown file (mode 0600), which opens.
    @Test func altReturnOpensANoteAsAMarkdownFile() async throws {
        let opened = Opened()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-md-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = model(VaultSearch(path: fixture, budget: 5), opened: opened)
        var toasts: [String] = []
        s.toast = { toasts.append($0) }
        s.query = "zucchini"
        await until(3) { s.results.contains { $0.title == "Garden reminder" } }
        s.select(s.results.firstIndex { $0.title == "Garden reminder" } ?? -1)
        #expect(s.selected?.alt == .markdown(shelf: "store", doc: "5a61bde5b95b6891"))
        #expect(SearchModel.keyHint(s.selected!) == "↩ Show all     ⌥↩ Open as Markdown")
        #expect(s.activateAlt() == .none, "no writer: no action")
        s.writeMarkdown = { try VaultMarkdown.write(title: $0, text: $1, shelf: $2, doc: $3, in: dir) }
        #expect(s.activateAlt() == .opened)
        await s.markdownTask?.value
        let f = dir.appendingPathComponent("store-5a61bde5b95b6891.md")
        #expect(opened.urls == [f] && toasts.isEmpty)
        #expect(try String(contentsOf: f, encoding: .utf8) == "# Garden reminder\n\nRemember to water the zucchini plants on Sunday.\n")
        let mode = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Return still shows the text in the panel
        #expect(s.activate() == nil && s.expanded != nil)
    }

    @Test func markdownFileNamesAreSafe() throws {
        #expect(VaultMarkdown.name(shelf: "store", doc: "9f8e") == "store-9f8e.md")
        #expect(VaultMarkdown.name(shelf: "store", doc: "../a b/c") == "store-.._a_b_c.md")
        #expect(VaultMarkdown.name(shelf: "x", doc: "é$;`") == "x-____.md")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-md-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = try VaultMarkdown.write(title: "T", text: "one", shelf: "store", doc: "d", in: dir)
        _ = try VaultMarkdown.write(title: "T", text: "two", shelf: "store", doc: "d", in: dir)
        #expect(f.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try String(contentsOf: f, encoding: .utf8) == "# T\n\ntwo\n", "a new write replaces the old file")
        let dmode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(dmode == 0o700)
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
        // a new query drops the old vault results when its first list shows
        s.query = "zzz"
        await until(3) { !s.pending }
        #expect(!s.results.contains { $0.kind == .vault })
    }

    @Test func noVaultGivesOnlyPackResults() async {
        let s = model(VaultSearch(path: "/nonexistent/vault.db"), opened: Opened())
        s.query = "sandhi"
        try? await Task.sleep(for: .milliseconds(250))
        #expect(s.results.map(\.packID) == ["coach"])
    }
}
