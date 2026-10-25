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
        let s = model(VaultSearch(path: fixture, budget: 5), opened: opened)
        s.query = "sandhi"
        #expect(s.results.map(\.packID) == ["coach"], "pack results show at once")
        await until(3) { s.results.count > 1 }
        #expect(s.results.map(\.packID) == ["coach", "vault:learning", "vault:store"])
        s.move(1)
        #expect(s.activate()?.title == "Vowel sandhi")
        #expect(opened.urls == [URL(string: "http://127.0.0.1:5077/c/vowel-sandhi")!])
    }

    @Test func aResultWithNoTargetCopies() async {
        let opened = Opened()
        let s = model(VaultSearch(path: fixture, budget: 5), opened: opened)
        s.query = "sunday plants"
        await until(3) { s.results.contains { $0.title == "Garden reminder" } }
        s.select(s.results.firstIndex { $0.title == "Garden reminder" } ?? -1)
        #expect(s.activate()?.title == "Garden reminder")
        #expect(opened.urls.isEmpty && s.pasteboard.string(forType: .string)?.contains("zucchini") == true)
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
