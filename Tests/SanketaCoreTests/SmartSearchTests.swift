import Testing
import Foundation
@testable import SanketaCore

private let query = "split the pane side by side"
private let items = [
    entry("tmux", "Split pane left/right", "prefix %"),
    entry("tmux", "Split pane top/bottom", "prefix \""),
    entry("vim", "Split window", ":vsplit"),
    entry("tmux", "New window", "prefix c"),
]

private func config(onDevice: Bool = false, appleFM: Bool = false, openai: Bool = false, suggest: Bool = true) -> LLMConfig {
    var c = LLMConfig(); c.onDevice = onDevice; c.appleFM = appleFM; c.openai = openai; c.suggest = suggest; return c
}

/// The fakes answer at once; the long default keeps a starved thread pool in a full run from timing them out.
private func search(fm: any Choosing, timeout: TimeInterval = 60) -> SmartSearch {
    SmartSearch(router: ModelRouter(config: config(appleFM: true), onDevice: nil, appleFM: fm, remote: nil), timeout: timeout)
}

@Suite struct SmartSearchTests {
    @Test func smartSearchPutsPicksFirst() async {
        let cands = Retrieval.candidates(query, items, context: ["tmux"])
        let (_, refs) = ChoicePrompt.build(task: .search(query), candidates: cands, maxPicks: 5)
        let e2 = refs["e2"]!
        let r = await search(fm: FixedChooser(picks: ["e2"])).results(query, items, context: ["tmux"])
        #expect(r.items[0] == e2)
        #expect(r.picked == [e2.id])
        #expect(r.note == nil)
        #expect(Set(r.items.map(\.id)).count == r.items.count)
        #expect(r.items == [e2] + cands.filter { $0 != e2 })
    }

    @Test func shortQueryDoesNotCallModel() async {
        let rec = RecordingChooser(responses: [.success(["e1"])])
        let r = await search(fm: rec).results("split", items, context: ["tmux"])
        #expect(await rec.prompts.isEmpty)
        #expect(r.items == Search.rank("split", items, context: ["tmux"]))
        #expect(r.note == nil && r.picked.isEmpty)
    }

    @Test func smartSearchFallsBackOnError() async {
        let local = Retrieval.candidates(query, items, context: ["tmux"])
        for (err, reason) in [(ChoiceError.badResponse, "failed"), (.notAllowed, "refused the request"),
                              (.noKey, "no key"), (.http(429), "HTTP 429")] {
            let r = await search(fm: ThrowingChooser(error: err)).results(query, items, context: ["tmux"])
            #expect(r.items == local)
            #expect(r.picked.isEmpty)
            #expect(r.note == "Plain search: throwing \(reason)")
        }
    }

    @Test func plainQueryUsesRankWhenItMatches() async {
        let r = await search(fm: ThrowingChooser(error: .badResponse)).results("split pane left", items, context: [])
        #expect(r.items == Search.rank("split pane left", items, context: []))
        #expect(!r.items.isEmpty)
    }

    // Under a full parallel run other suites can hold the thread pool for seconds, so there is no wall-clock limit:
    // the result must come before the 15 s fake answers, with the timeout or cancellation reported.
    @Test func smartSearchTimesOut() async {
        let slow = SlowChooser(seconds: 15)
        let r = await search(fm: slow, timeout: 0.3).results(query, items, context: ["tmux"])
        #expect(!slow.finished)
        #expect(r.items == Retrieval.candidates(query, items, context: ["tmux"]))
        #expect(r.note?.contains("timed out") == true)
    }

    @Test func stubbornChooserCannotHoldResults() async {
        let slow = StubbornChooser(seconds: 15)
        let r = await search(fm: slow, timeout: 0.3).results(query, items, context: ["tmux"])
        #expect(!slow.finished)
        #expect(r.items == Retrieval.candidates(query, items, context: ["tmux"]))
        #expect(r.picked.isEmpty)
        #expect(r.note == "Plain search: stubborn timed out")
    }

    @Test func cancelledSearchReturnsAtOnce() async {
        let slow = StubbornChooser(seconds: 15)
        let t = Task { await search(fm: slow, timeout: 30).results(query, items, context: ["tmux"]) }
        try? await Task.sleep(for: .milliseconds(200))
        t.cancel()
        let r = await t.value
        #expect(!slow.finished)
        #expect(r.note == "Plain search: stubborn failed")
        #expect(r.picked.isEmpty)
        #expect(r.items == Retrieval.candidates(query, items, context: ["tmux"]))
    }

    @Test func noCandidatesSkipsTheModel() async {
        let rec = RecordingChooser(responses: [.success(["e1"])])
        for q in ["how to do", "zzqx wwvy kkjp"] {
            let r = await search(fm: rec).results(q, items, context: ["tmux"])
            #expect(r.items == Search.rank(q, items, context: ["tmux"]))
            #expect(r.note == nil && r.picked.isEmpty)
        }
        #expect(await rec.prompts.isEmpty)
    }

    @Test func duplicateCandidatesGetOneRef() async {
        let dup = items + [items[0], items[0]]
        let rec = RecordingChooser(responses: [.success(["e1"])])
        let r = await search(fm: rec).results(query, dup, context: ["tmux"])
        let p = await rec.prompts
        #expect(p.count == 1)
        #expect(p[0].lines.filter { $0.contains("Split pane left/right") }.count == 1)
        #expect(Set(r.items.map(\.id)).count == r.items.count)
        #expect(r.picked.count == 1)

        let failed = await search(fm: ThrowingChooser(error: .badResponse)).results(query, dup, context: ["tmux"])
        #expect(failed.note != nil)
        #expect(Set(failed.items.map(\.id)).count == failed.items.count)
    }

    @Test func noChooserGivesRouterNote() async {
        let s = SmartSearch(router: ModelRouter(config: config(), onDevice: nil, appleFM: nil, remote: nil), timeout: 1)
        let r = await s.results(query, items, context: ["tmux"])
        #expect(r.note == "Plain search: no model turned on")
        #expect(!r.items.isEmpty)
    }

    @Test func contextExceededRetriesHalved() async {
        let rec = RecordingChooser(responses: [.failure(.contextExceeded), .success(["e1"])])
        let r = await search(fm: rec).results(query, items, context: ["tmux"])
        let ps = await rec.prompts
        #expect(ps.count == 2)
        #expect(ps[1].refs.count == ps[0].refs.count / 2)
        #expect(r.picked.count == 1)
        #expect(r.items[0] == Retrieval.candidates(query, items, context: ["tmux"])[0])
        #expect(r.note == nil)
    }

    @Test func remoteChooserNeverSeesMenuItems() async {
        let menu = SearchItem(packID: "app:com.apple.Terminal", packName: "Terminal Menus", kind: .key,
                              title: "Split pane side by side", detail: "⌘D")
        let all = items + [menu]
        let remote = RecordingChooser(isRemote: true)
        let rs = SmartSearch(router: ModelRouter(config: config(openai: true), onDevice: nil, appleFM: nil, remote: remote), timeout: 60)
        let r = await rs.results(query, all, context: ["tmux"])
        let sent = await remote.prompts
        #expect(sent.count == 1)
        #expect(!sent.flatMap(\.lines).contains { $0.contains("Terminal Menus") })
        #expect(!sent[0].userText.contains("Terminal Menus"))
        #expect(r.items.contains(menu))

        let local = RecordingChooser()
        _ = await search(fm: local).results(query, all, context: ["tmux"])
        #expect(await local.prompts.flatMap(\.lines).contains { $0.contains("Terminal Menus") })
    }

    @Test func routerOrder() {
        let up = FixedChooser(picks: [], status: .available)
        let ondev = FakeOnDevice(up)
        let ondevDown = FakeOnDevice(FixedChooser(picks: [], status: .unavailable("on-device model not downloaded")))
        var fm = FixedChooser(picks: [], status: .available); fm.name = "fm"
        var fmDown = FixedChooser(picks: [], status: .unavailable("Apple Intelligence is off")); fmDown.name = "fm"
        var remote = FixedChooser(picks: [], status: .available, isRemote: true); remote.name = "remote"
        let all = config(onDevice: true, appleFM: true, openai: true)

        #expect(ModelRouter(config: all, onDevice: ondev, appleFM: fm, remote: remote).searchChooser()?.name == "on-device")
        #expect(ModelRouter(config: all, onDevice: ondevDown, appleFM: fm, remote: remote).searchChooser()?.name == "fm")
        let r3 = ModelRouter(config: all, onDevice: ondevDown, appleFM: fmDown, remote: remote)
        #expect(r3.searchChooser()?.name == "remote")
        #expect(r3.searchNote() == nil)

        let r4 = ModelRouter(config: config(onDevice: true, appleFM: true), onDevice: ondevDown, appleFM: fmDown, remote: remote)
        #expect(r4.searchChooser() == nil)
        #expect(r4.searchNote() == "Plain search: on-device model not downloaded; Apple Intelligence is off")

        #expect(ModelRouter(config: config(appleFM: true), onDevice: ondev, appleFM: fm, remote: remote).searchChooser()?.name == "fm")
        #expect(ModelRouter(config: config(), onDevice: ondev, appleFM: fm, remote: remote).searchNote() == "Plain search: no model turned on")

        let onlyRemote = ModelRouter(config: all, onDevice: ondevDown, appleFM: fmDown, remote: remote)
        #expect(onlyRemote.suggestChooser() == nil)
        #expect(ModelRouter(config: all, onDevice: ondevDown, appleFM: fm, remote: remote).suggestChooser()?.name == "fm")
        #expect(ModelRouter(config: config(onDevice: true, suggest: false), onDevice: ondev, appleFM: nil, remote: nil).suggestChooser() == nil)
    }

    @Test func prewarmReachesOnlyTheSearchChooser() async {
        let a = PrewarmCounter(), b = PrewarmCounter()
        ModelRouter(config: config(onDevice: true, appleFM: true), onDevice: a, appleFM: b, remote: nil).prewarm()
        #expect(a.count == 1 && b.count == 0)
    }

    @Test func suggestCandidatesFromRecentCommands() {
        let lib = PackLibrary.load(bundled: bundledPacksDir, user: nil)
        let all = lib.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
        let recent = ["git status", "git log --oneline | head -n 5"].map { HistoryEntry(command: $0, shell: .bash) }
        let gitItems = all.filter { $0.packID == "git" }
        let excluded = Set(gitItems.prefix(2).map(\.id))
        let got = SmartSuggest.candidates(recent: recent, library: lib, items: all, excluding: excluded)
        let allowed = Set(["git", "head"].compactMap { lib.pack(process: $0, argv: [$0])?.id })
        #expect(!got.isEmpty)
        #expect(got[0].packID == "git")
        #expect(got.allSatisfy { allowed.contains($0.packID) && $0.kind != .suggestion })
        #expect(got.allSatisfy { !excluded.contains($0.id) })
        #expect(got.count <= 30)
    }

    @Test func suggestSkipsWrappersAndOrdersByRecency() {
        let lib = PackLibrary.load(bundled: bundledPacksDir, user: nil)
        let all = lib.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
        let recent = ["sudo git status", "env tmux ls", "ls"].map { HistoryEntry(command: $0, shell: .bash) }
        let got = SmartSuggest.candidates(recent: recent, library: lib, items: all, excluding: [], limit: 500)
        #expect(got.first?.packID == "tmux")
        #expect(Set(got.map(\.packID)) == ["tmux", "git"])
    }

    @Test func suggestPickUsesOnDeviceOnly() async {
        let lib = PackLibrary.load(bundled: bundledPacksDir, user: nil)
        let all = lib.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
        let recent = [HistoryEntry(command: "git status", shell: .bash)]
        let cands = SmartSuggest.candidates(recent: recent, library: lib, items: all, excluding: [])
        let fm = FixedChooser(picks: ["e2", "e5", "e9"])
        let r = ModelRouter(config: config(appleFM: true), onDevice: nil, appleFM: fm, remote: nil)
        let got = await SmartSuggest.pick(recent: recent, library: lib, items: all, excluding: [], router: r, timeout: 60)
        #expect(got == [cands[1], cands[4]])

        let remote = RecordingChooser(responses: [.success(["e2"])], isRemote: true)
        let rr = ModelRouter(config: config(openai: true), onDevice: nil, appleFM: nil, remote: remote)
        #expect(await SmartSuggest.pick(recent: recent, library: lib, items: all, excluding: [], router: rr, timeout: 60).isEmpty)
        #expect(await remote.prompts.isEmpty)

        let bad = ModelRouter(config: config(appleFM: true), onDevice: nil, appleFM: ThrowingChooser(error: .badResponse), remote: nil)
        #expect(await SmartSuggest.pick(recent: recent, library: lib, items: all, excluding: [], router: bad, timeout: 60).isEmpty)
    }
}

final class PrewarmCounter: OnDeviceChooser, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    var name: String { "counter" }
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] { [] }
    func prewarm() { lock.withLock { n += 1 } }
}
