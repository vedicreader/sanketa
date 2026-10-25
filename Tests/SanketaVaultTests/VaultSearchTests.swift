import Foundation
import Testing
import Adhara
import SanketaCore
@testable import SanketaVault

/// Fixtures/vault.db comes from scripts/make_vault_fixture.py: vishalakshi and abhyasa wrote it, with the tokenizer
/// chain of the real vault. Tests open it read-only.
let fixture = Bundle.module.url(forResource: "vault", withExtension: "db", subdirectory: "Fixtures")!.path

@Suite struct VaultSearchTests {
    @Test func listsShelvesAndSkipsTestShelves() throws {
        let db = try Database(path: fixture, readonly: true)
        #expect(try VaultSearch.shelves(db) == ["learning", "store"])
    }

    @Test func findsAConceptOnLearningAndADocOnTheMainShelf() async {
        let r = await VaultSearch(path: fixture, budget: 5).search("sandhi")
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

    @Test func aDocWithNoTargetCopiesItsSnippet() async {
        let r = await VaultSearch(path: fixture, budget: 5).search("zucchini")
        #expect(Set(r.map(\.title)) == ["Zucchini watering", "Garden reminder"], "the tmp shelf stays out")
        let note = r.first { $0.title == "Garden reminder" }
        #expect(note?.open == nil && note?.copyText?.contains("zucchini") == true)
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
        let base = URL(string: "http://127.0.0.1:5077")
        let have = { (p: String) in p == "/Users/me/notes/a.md" }
        func t(_ s: String) -> URL? { VaultSearch.target(s, learningURL: base, exists: have) }
        #expect(t("learning://concept/vowel-sandhi") == URL(string: "http://127.0.0.1:5077/c/vowel-sandhi"))
        #expect(t("learning://concept/") == nil)
        #expect(t("learning://concept/../admin") == nil)
        #expect(t("learning://attempt/abc") == nil)
        #expect(t("https://example.com/a?b=1") == URL(string: "https://example.com/a?b=1"))
        #expect(t("http://example.com") == URL(string: "http://example.com"))
        #expect(t("/Users/me/notes/a.md") == URL(fileURLWithPath: "/Users/me/notes/a.md"))
        #expect(t("file:///Users/me/notes/a.md") == URL(string: "file:///Users/me/notes/a.md"))
        #expect(t("/Users/me/notes/gone.md") == nil)
        #expect(t("note:01d6786c1498") == nil)
        #expect(t("research://289acd5a3356a8b7") == nil)
        #expect(t("agent-note://0636d6fc") == nil)
        #expect(t("report") == nil)
        #expect(VaultSearch.target("learning://concept/x", learningURL: nil) == nil)
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
        #expect(err == nil && !c.vault.enabled && c.vault.path == "/tmp/v.db" && c.vault.learningURL == "http://localhost:9")
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
