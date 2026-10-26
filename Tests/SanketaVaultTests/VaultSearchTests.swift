import Foundation
import Testing
import Adhara
import SanketaCore
import SanketaUI
@testable import SanketaVault

/// Fixtures/vault.db comes from scripts/make_vault_fixture.py: vishalakshi and abhyasa wrote it, with the tokenizer
/// chain of the real vault. Tests open it read-only.
let fixture = Bundle.module.url(forResource: "vault", withExtension: "db", subdirectory: "Fixtures")!.path
/// abhyasa on, and it answers; no request is made
let abhyasaUp = AbhyasaProbe(base: URL(string: "http://127.0.0.1:5077")!) { _ in true }

@Suite struct VaultSearchTests {
    @Test func listsShelvesAndSkipsTestShelves() throws {
        let db = try Database(path: fixture, readonly: true)
        #expect(try VaultSearch.shelves(db) == ["learning", "store"])
    }

    @Test func findsAConceptOnLearningAndADocOnTheMainShelf() async {
        let r = await VaultSearch(path: fixture, abhyasa: abhyasaUp, budget: 5).search("sandhi")
        let concept = r.first { $0.packID == "vault:learning" }
        #expect(concept?.title == "Vowel sandhi" && concept?.packName == "learning" && concept?.kind == .vault)
        #expect(concept?.open == URL(string: "http://127.0.0.1:5077/c/vowel-sandhi"))
        #expect(concept?.tags == ["concept"])
        let doc = r.first { $0.packID == "vault:store" }
        #expect(doc?.title == "Notes on sandhi" && doc?.packName == "vault")
        #expect(doc?.open == URL(string: "https://example.com/sandhi"))
        #expect(doc?.detail.localizedCaseInsensitiveContains("sandhi") == true)
        // learning first, then the main shelf
        #expect(r.map(\.packID) == ["vault:learning", "vault:store"])
    }

    @Test func aNoteOpensInTheAbhyasaViewerOnlyWhenAbhyasaIsOn() async {
        let r = await VaultSearch(path: fixture, budget: 5).search("zucchini")
        #expect(Set(r.map(\.title)) == ["Zucchini watering", "Garden reminder"], "the tmp shelf stays out")
        #expect(r.allSatisfy { $0.open == nil }, "abhyasa off: a note and a concept have no target")
        let on = await VaultSearch(path: fixture, abhyasa: abhyasaUp, budget: 5).search("zucchini")
        #expect(on.first { $0.title == "Garden reminder" }?.open == URL(string: "http://127.0.0.1:5077/v/store/5a61bde5b95b6891"))
        #expect(on.first { $0.title == "Zucchini watering" }?.open == URL(string: "http://127.0.0.1:5077/c/zucchini-watering"))
    }

    @Test func stemsAndPrefixes() async {
        // porter: "joining" finds "joins"; a prefix finds the whole word
        #expect(await VaultSearch(path: fixture, budget: 5).search("joining").contains { $0.title == "Notes on sandhi" })
        #expect(await VaultSearch(path: fixture, budget: 5).search("zucch").count == 2)
    }

    @Test func missingOrBadVaultGivesNothing() async throws {
        #expect(await VaultSearch(path: "/nonexistent/vault.db").search("sandhi").isEmpty)
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-bad-\(UUID().uuidString).db")
        try Data("not sqlite".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        #expect(await VaultSearch(path: bad.path).search("sandhi").isEmpty)
    }

    @Test func shortWordsAndSymbolsGiveNothing() async {
        let v = VaultSearch(path: fixture, budget: 5)
        #expect(await v.search("a").isEmpty)
        #expect(await v.search("\" * ( )").isEmpty)
        // quotes in a word cannot break the FTS5 query
        #expect(await v.search("sandhi\"").contains { $0.title == "Vowel sandhi" })
    }

    @Test func openTargets() {
        let base = AbhyasaTarget.web(URL(string: "http://127.0.0.1:5077")!)
        let have = { (p: String) in p == "/Users/me/notes/a.md" }
        func t(_ s: String, _ a: AbhyasaTarget? = base) -> URL? { VaultLinks.open(s, shelf: "ramabana", doc: "d1", abhyasa: a, exists: have) }
        #expect(t("learning://concept/vowel-sandhi") == URL(string: "http://127.0.0.1:5077/c/vowel-sandhi"))
        #expect(t("learning://concept/") == nil)
        #expect(t("learning://concept/../admin") == nil)
        #expect(t("https://example.com/a?b=1") == URL(string: "https://example.com/a?b=1"))
        #expect(t("http://example.com") == URL(string: "http://example.com"))
        #expect(t("/Users/me/notes/a.md") == URL(fileURLWithPath: "/Users/me/notes/a.md"))
        #expect(t("file:///Users/me/notes/a.md") == URL(string: "file:///Users/me/notes/a.md"))
        // anything else opens in the abhyasa viewer
        let viewer = URL(string: "http://127.0.0.1:5077/v/ramabana/d1")
        for s in ["/Users/me/notes/gone.md", "note:01d6786c1498", "ramabana://session/abc", "ramabana://memory/x", "report",
                  "learning://attempt/abc"] {
            #expect(t(s) == viewer, "\(s)")
        }
        #expect(VaultLinks.open("note:x", shelf: "store", doc: "a/../b", abhyasa: base) == nil, "a doc id must be safe in a path")
        // abhyasa off (or not answering): web pages and files only
        #expect(t("learning://concept/x", nil) == nil && t("note:x", nil) == nil && t("ramabana://session/abc", nil) == nil)
        #expect(t("https://example.com/a", nil) == URL(string: "https://example.com/a"))
        #expect(t("/Users/me/notes/a.md", nil) == URL(fileURLWithPath: "/Users/me/notes/a.md"))
    }

    /// With Abhyasa.app installed, links go to the app: they work on any port, and they start the app.
    @Test func appLinksWhenAbhyasaIsInstalled() {
        let have = { (p: String) in p == "/Users/me/notes/a.md" }
        func t(_ s: String, shelf: String = "ramabana", doc: String = "d1") -> URL? {
            VaultLinks.open(s, shelf: shelf, doc: doc, abhyasa: .app, exists: have)
        }
        #expect(t("learning://concept/vowel-sandhi") == URL(string: "abhyasa://concept/vowel-sandhi"))
        #expect(t("note:sanketa-1a2b", shelf: "store", doc: "9f8e7d6c") == URL(string: "abhyasa://vault/store/9f8e7d6c"))
        #expect(t("ramabana://session/abc") == URL(string: "abhyasa://vault/ramabana/d1"))
        // a web page and a file on this Mac still open as they are
        #expect(t("https://example.com/a") == URL(string: "https://example.com/a"))
        #expect(t("/Users/me/notes/a.md") == URL(fileURLWithPath: "/Users/me/notes/a.md"))
        // each part must be safe
        #expect(t("learning://concept/../admin") == nil && t("learning://concept/a b") == nil)
        #expect(t("note:x", shelf: "store", doc: "a/../b") == nil && t("note:x", shelf: "st ore", doc: "d") == nil)
        #expect(t("note:x", shelf: "store", doc: "..") == nil)
    }

    /// The app wins over the server, and no request goes out when the app is there.
    @Test func probeChoosesTheAppFirst() async {
        final class Count: @unchecked Sendable { var n = 0 }
        let c = Count(), base = URL(string: "http://127.0.0.1:5077")!
        let app = AbhyasaProbe(base: base, app: { true }) { _ in c.n += 1; return true }
        #expect(await app.up() == .app && app.cached == .app && c.n == 0)
        let web = AbhyasaProbe(base: base, app: { false }) { _ in c.n += 1; return true }
        #expect(web.cached == nil, "no answer yet")
        #expect(await web.up() == .web(base) && web.cached == .web(base) && c.n == 1)
        let none = AbhyasaProbe(base: nil, app: { false }) { _ in c.n += 1; return true }
        #expect(await none.up() == nil && c.n == 1, "no server address: no request")
    }

    /// ⌥Return on a document with no page and no file: open it as a Markdown file.
    @Test func markdownActionOnlyWithoutAPageOrAFile() {
        let have = { (p: String) in p == "/Users/me/notes/a.md" }
        func m(_ s: String, shelf: String = "store", doc: String? = "d1") -> VaultAlt? { VaultLinks.markdown(s, shelf: shelf, doc: doc, exists: have) }
        #expect(m("note:sanketa-1a2b") == .markdown(shelf: "store", doc: "d1"))
        #expect(m("/Users/me/notes/gone.md") == .markdown(shelf: "store", doc: "d1"), "a file that is gone")
        #expect(m("https://example.com/a") == nil && m("/Users/me/notes/a.md") == nil)
        #expect(m("note:x", doc: nil) == nil && m("note:x", doc: "a/b") == nil && m("note:x", shelf: "a;b") == nil)
    }

    /// A note that ⌘S or ⇧⌘S saved: vishalakshi gives it the source `note:<key>` on the main shelf, as other notes.
    @Test func aSavedSanketaNoteOpensLikeOtherNotes() {
        func item(_ a: AbhyasaTarget?) -> SearchItem {
            VaultSearch.item(shelf: "store", doc: "9f8e7d6c5b4a3210", title: "tmux prefix d detaches", detail: "x",
                             source: "note:sanketa-1a2b3c4d5e6f", kind: "note", abhyasa: a)
        }
        let on = item(.web(URL(string: "http://127.0.0.1:5077")!))
        let md = VaultAlt.markdown(shelf: "store", doc: "9f8e7d6c5b4a3210")
        #expect(on.open == URL(string: "http://127.0.0.1:5077/v/store/9f8e7d6c5b4a3210") && on.alt == md && on.packName == "vault")
        #expect(item(.app).open == URL(string: "abhyasa://vault/store/9f8e7d6c5b4a3210"))
        #expect(item(nil).open == nil && item(nil).alt == md, "no abhyasa: Return shows all the text in the panel")
        #expect(SearchModel.keyHint(on) == "↩ Open     ⌥↩ Open as Markdown")
        #expect(SearchModel.keyHint(item(nil)) == "↩ Show all     ⌥↩ Open as Markdown")
    }

    @Test func altActions() {
        let files = ["/r/memory/proj/MEMORY.md", "/r/learned/AGENTS.md", "/r/learned/skills/tdd/SKILL.md"]
        func a(_ s: String) -> VaultAlt? { VaultLinks.alt(s, config: "/r", exists: files.contains) }
        #expect(a("ramabana://session/2026-10-21-ab12") == .resume("2026-10-21-ab12"))
        #expect(a("ramabana://memory/proj") == .file(URL(fileURLWithPath: files[0])))
        #expect(a("ramabana://learned/AGENTS.md") == .file(URL(fileURLWithPath: files[1])))
        #expect(a("ramabana://learned/skills/tdd") == .file(URL(fileURLWithPath: files[2])))
        #expect(a("ramabana://memory/gone") == nil, "no file")
        #expect(a("ramabana://session/a;rm") == nil && a("ramabana://memory/..") == nil && a("ramabana://session/") == nil)
        #expect(a("learning://concept/x") == nil && a("https://example.com") == nil)
    }

    @Test func abhyasaProbeKeepsItsAnswer() async {
        final class Count: @unchecked Sendable { var n = 0 }
        let c = Count()
        let p = AbhyasaProbe(base: URL(string: "http://127.0.0.1:5077")!, keep: 60) { _ in c.n += 1; return true }
        let first = await p.up(), second = await p.up()
        #expect(first == .web(URL(string: "http://127.0.0.1:5077")!) && second != nil && c.n == 1)
        let down = AbhyasaProbe(base: URL(string: "http://127.0.0.1:5077")!) { _ in false }
        #expect(await down.up() == nil)
        // a real check on a port where nothing listens is quick and says no
        let t = Date()
        #expect(await AbhyasaProbe(base: URL(string: "http://127.0.0.1:9")!).up() == nil)
        #expect(Date().timeIntervalSince(t) < 1)
    }

    @Test func snippetStartsNearTheWord() {
        let text = String(repeating: "filler word ", count: 30) + "the sandhi rule\n\nends here"
        let s = VaultSearch.snippet(text, ["sandhi"])
        #expect(s.hasPrefix("…") && s.contains("the sandhi rule ends here") && !s.contains("\n"))
        #expect(VaultSearch.snippet("short text", ["none"]) == "short text")
    }

    @Test func vaultPathOrder() {
        var c = VaultConfig()
        let home = NSHomeDirectory()
        #expect(c.resolvedPath(env: [:]) == home + "/.vishalakshi/vault.db")
        #expect(c.resolvedPath(env: ["ABHYASA_VAULT": "/a.db"]) == "/a.db")
        #expect(c.resolvedPath(env: ["ABHYASA_VAULT": "/a.db", "VISHALAKSHI_VAULT": "/v.db"]) == "/v.db")
        c.path = "~/x.db"
        #expect(c.resolvedPath(env: ["VISHALAKSHI_VAULT": "/v.db"]) == home + "/x.db")
    }

    @Test func vaultConfigFromTOML() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-vault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("config.toml")
        try? "[vault]\nenabled = false\npath = \"/tmp/v.db\"\nlearning_url = \"http://localhost:9\"\n".write(to: f, atomically: true, encoding: .utf8)
        let (c, err, _) = Config.load(f)
        #expect(err == nil && !c.vault.enabled && c.vault.path == "/tmp/v.db" && c.abhyasa.url == "http://localhost:9")
        #expect(c.abhyasa.enabled && c.abhyasa.base == URL(string: "http://localhost:9"), "abhyasa is on when it is there")
        #expect(Config.load(dir.appendingPathComponent("none.toml")).config.vault == VaultConfig())
    }

    /// Read-only, on the user's real vault: `SANKETA_REAL_VAULT=1 swift test --filter realVault`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SANKETA_REAL_VAULT"] == "1"))
    func realVault() async throws {
        let path = VaultConfig().resolvedPath()
        let db = try Database(path: path, readonly: true)
        print("shelves:", try VaultSearch.shelves(db))
        let v = VaultSearch(path: path)
        for q in ["sqlite", "sandhi", "tmux session", "krishna", "message queue"] {
            let t = Date()
            let r = await v.search(q)
            print(String(format: "%@: %d results in %.0f ms", q, r.count, Date().timeIntervalSince(t) * 1000))
            for i in r.prefix(5) { print("  [\(i.packName)] \(i.title) | \(i.open?.absoluteString ?? "copy")") }
        }
    }
}
