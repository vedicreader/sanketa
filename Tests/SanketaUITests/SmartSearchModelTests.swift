import AppKit
import Combine
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaUI

/// Answers `picks` after `delay` seconds (cancellably) and counts its calls.
private final class TestChooser: Choosing, @unchecked Sendable {
    let picks: [String], delay: Double
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    let name = "test model", isRemote = false
    init(_ picks: [String], delay: Double = 0) { self.picks = picks; self.delay = delay }
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] {
        lock.withLock { calls += 1 }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return picks
    }
}

private let items: [SearchItem] = [
    ("tmux", "Split pane left/right", "prefix %"), ("tmux", "Split pane top/bottom", "prefix \""), ("tmux", "New window", "prefix c"),
    ("tmux", "Zoom pane", "prefix z"), ("vim", "Split window side by side", ":vsplit"), ("vim", "Copy line to the clipboard", "\"+yy"),
    ("kitty", "Copy to clipboard", "⌘C"), ("kitty", "New tab", "⌘T"),
].map { SearchItem(packID: $0.0, packName: $0.0, kind: .key, title: $0.1, detail: $0.2) }

/// The FM tier filled by `c`: the router's order is on-device, Apple Foundation Models, OpenAI.
private func smart(_ c: (any Choosing)?) -> SmartSearch {
    SmartSearch(router: ModelRouter(config: LLMConfig(), onDevice: nil, appleFM: c, remote: nil), timeout: 60)
}

@MainActor private func model(_ c: (any Choosing)?, debounce: TimeInterval = 0.1) -> SearchModel {
    let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")), smart: smart(c), debounce: debounce)
    s.setSource(extra: items)
    return s
}

/// Polls on the main actor until `cond` holds, for about `seconds`. It counts polls, not wall time: while other suites
/// hold the main thread (focus tests on a locked screen), the polls wait too, and the budget is not used up.
@MainActor private func until(_ seconds: Double, _ cond: () -> Bool) async {
    for _ in 0..<Int(seconds * 50) where !cond() { try? await Task.sleep(for: .milliseconds(20)) }
}

@MainActor @Suite(.serialized) struct SmartSearchModelTests {
    @Test func smartResultReplacesListWhenQueryUnchanged() async throws {
        let s = model(TestChooser(["e2"]))
        s.query = "split pane side by side"
        let local = s.results
        #expect(local == Search.blend(s.query, Search.rank(s.query, items, context: [])))
        #expect(s.picked.isEmpty && s.note == nil)
        await until(3) { !s.picked.isEmpty }
        #expect(s.picked.count == 1 && s.picked.contains(s.results[0].id))
        #expect(s.note == nil)
        // the pick is a loaded entry, and the plain results stay below it
        #expect(Set(s.results.map(\.id)).isSubset(of: Set(items.map(\.id))))
        #expect(Set(local.map(\.id)).isSubset(of: Set(s.results.map(\.id))))
        // a new query drops the picks at once
        s.query = "zoom"
        #expect(s.picked.isEmpty && s.note == nil && s.results.first?.title == "Zoom pane")
    }

    @Test func staleSmartResultDropped() async throws {
        let a = "split the pane side by side", b = "copy a line to the clipboard"
        let aPick = try #require(await smart(TestChooser(["e1"])).results(a, items, context: []).picked.first)
        let bPick = try #require(await smart(TestChooser(["e1"])).results(b, items, context: []).picked.first)
        #expect(aPick != bPick)
        let c = TestChooser(["e1"], delay: 0.3)
        let s = model(c)
        var seen: [Set<String>] = []
        let sub = s.$picked.sink { seen.append($0) }
        s.query = a
        try await Task.sleep(for: .milliseconds(150))
        s.query = b
        await until(4) { !s.picked.isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        sub.cancel()
        #expect(s.picked == [bPick])
        #expect(!seen.contains { $0.contains(aPick) })
        #expect(s.results.contains { $0.id == bPick }, "a late pick joins the list; it does not move the rows that show")
    }

    @Test func typingQuicklyCallsModelOnce() async throws {
        let c = TestChooser([])
        let s = model(c, debounce: 0.25)
        for q in ["how", "how do", "how do I", "how do I split", "how do I split the", "how do I split the pane"] {
            s.query = q
            try await Task.sleep(for: .milliseconds(30))
        }
        await until(3) { c.count > 0 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(c.count == 1)
    }

    @Test func plainNoteShowsWithoutChooser() async throws {
        let s = model(nil)
        s.query = "split pane left"
        let local = s.results
        await until(3) { s.note != nil }
        #expect(s.note?.hasPrefix("Plain search:") == true)
        #expect(s.results == local && s.picked.isEmpty)
    }

    @Test func shortQueriesNeverCallModel() async throws {
        let c = TestChooser(["e1"])
        let s = model(c)
        s.query = "split pane"
        try await Task.sleep(for: .milliseconds(400))
        #expect(c.count == 0 && s.picked.isEmpty && s.note == nil)
        // a new router takes over for the next query
        let d = TestChooser(["e1"])
        s.setSmart(smart(d))
        s.query = "split the pane side by side"
        await until(3) { !s.picked.isEmpty }
        #expect(c.count == 0 && d.count == 1)
    }

    @Test func endingSearchCancelsPendingCall() async throws {
        let c = TestChooser(["e1"])
        let s = model(c, debounce: 0.2)
        s.query = "split the pane side by side"
        s.clear()
        try await Task.sleep(for: .milliseconds(500))
        #expect(c.count == 0 && s.results.isEmpty && s.picked.isEmpty)
    }
}

@Suite struct StatusMenusTests {
    func openAI(_ on: Bool = true, model: String = "") -> LLMConfig {
        var c = LLMConfig()
        c.openai = on; c.openaiModel = model
        return c
    }

    @Test func modelMenuOffMakesOneDisabledLine() {
        #expect(StatusMenus.modelLines(config: openAI(false), models: ["gpt-5-nano"], loading: true, failure: nil)
                == [MenuLine("Turn on Use OpenAI first", enabled: false)])
    }

    @Test func modelMenuListsCachedModelsWithCheapestFirst() {
        let ids = ["gpt-4.1", "gpt-4o-mini", "gpt-5-nano"]
        let l = StatusMenus.modelLines(config: openAI(), models: ids, loading: true, failure: nil)
        #expect(l.map(\.title) == ["Cheapest (now GPT-5 Nano)", "GPT-4.1", "GPT-4o Mini", "GPT-5 Nano", "Loading models…"])
        #expect(l.map(\.checked) == [true, false, false, false, false])
        #expect(l[0].action == .cheapest && l[1].action == .model("gpt-4.1") && !l[4].enabled)
        let pinned = StatusMenus.modelLines(config: openAI(model: "gpt-4.1"), models: ids, loading: false, failure: nil)
        #expect(pinned.filter(\.checked).map(\.title) == ["GPT-4.1"] && pinned.count == 4)
        // before the first list, or after a failure, the saved id still shows
        let none = StatusMenus.modelLines(config: openAI(model: "my-model"), models: nil, loading: false,
                                            failure: StatusMenus.failed)
        #expect(none.map(\.title) == ["Cheapest", "my-model", "Could not load the model list"])
        #expect(none[1].checked && !none[2].enabled)
    }

    @Test func titlesNameTheProvider() {
        #expect(StatusMenus.modelTitle(provider: "OpenAI") == "OpenAI Model")
        #expect(StatusMenus.modelTitle(provider: "llm.example.com") == "Model (llm.example.com)")
        #expect(StatusMenus.keyTitle(provider: "OpenAI") == "OpenAI Key…")
        #expect(StatusMenus.keyTitle(provider: "llm.example.com") == "API Key (llm.example.com)…")
        #expect(StatusMenus.failure(ChoiceError.noKey, provider: "OpenAI") == "No API key. Choose OpenAI Key…")
        #expect(StatusMenus.failure(ChoiceError.noKey, provider: "llm.example.com") == "No API key. Choose API Key (llm.example.com)…")
        #expect(StatusMenus.failure(ChoiceError.http(500), provider: "OpenAI") == "Could not load the model list")
    }

    /// An 8 GB Mac: no Gemma line unless Gemma is downloaded.
    let small: UInt64 = 8 << 30

    @Test func onDeviceMenuWithoutMLXBuild() {
        let l = StatusMenus.onDeviceLines(selected: .qwen4b, installed: [], progress: nil, mlxReady: false, memory: small)
        #expect(l.map(\.title) == ["Qwen3.5-4B: not downloaded", "Needs the MLX build", "Download Qwen3.5-4B (3.1 GB)",
                                   "Download Qwen3.5-2B (1.7 GB)", "No On-Device Model", "Remove Downloaded Models"])
        #expect(l.allSatisfy { !$0.enabled || $0.action == .turnOff }, "only turning the model off works")
    }

    @Test func onDeviceMenuStates() {
        let ready = StatusMenus.onDeviceLines(selected: .qwen4b, installed: [.qwen2b], progress: nil, mlxReady: true, memory: small)
        #expect(ready.map(\.title) == ["Qwen3.5-4B: not downloaded", "Download Qwen3.5-4B (3.1 GB)", "Use Qwen3.5-2B",
                                       "No On-Device Model", "Remove Downloaded Models"])
        #expect(ready.map(\.enabled) == [false, true, true, true, true])
        #expect(ready[1].action == .download(.qwen4b) && ready[2].action == .use(.qwen2b))
        let busy = StatusMenus.onDeviceLines(selected: .qwen2b, installed: [.qwen2b], progress: 0.427, mlxReady: true, memory: small)
        #expect(busy[0].title == "Downloading… 42 %" && busy.allSatisfy { !$0.enabled })
        let done = StatusMenus.onDeviceLines(selected: .qwen2b, installed: [.qwen2b], progress: nil, mlxReady: true, memory: small)
        #expect(done[0].title == "Qwen3.5-2B: downloaded" && done[2].checked && !done[2].enabled)
        let failed = StatusMenus.onDeviceLines(selected: .qwen4b, installed: [], progress: nil, mlxReady: true,
                                               error: "The connection stopped.", memory: small)
        #expect(failed.prefix(2).map(\.title) == ["Qwen3.5-4B: not downloaded", "The connection stopped."] && !failed[1].enabled)
    }

    @Test func gemmaThatDoesNotLoadOffersTheSixBitModel() {
        let l = StatusMenus.onDeviceLines(selected: .gemma4e4b, installed: [.gemma4e4b], progress: nil, mlxReady: true,
                                          memory: 36 << 30, failed: [.gemma4e4b])
        #expect(l.map(\.title) == ["Gemma 4 E4B: did not load", "Use Gemma 4 E4B", "Download Qwen3.5-4B (3.1 GB)",
                                   "Download Qwen3.5-2B (1.7 GB)", "Download Qwen3.5-4B 6-bit (4.1 GB)", "No On-Device Model",
                                   "Remove Downloaded Models"])
        #expect(l[4].action == .download(.qwen4b6) && l[4].enabled)
        // without a failure the 6-bit model does not show
        #expect(!StatusMenus.onDeviceLines(selected: .gemma4e4b, installed: [], progress: nil, mlxReady: true, memory: 36 << 30)
            .contains { $0.title.contains("6-bit") })
    }

    @Test func onDeviceMenuOffersGemmaWithSixteenGigabytes() {
        let l = StatusMenus.onDeviceLines(selected: .gemma4e4b, installed: [.qwen4b], progress: nil, mlxReady: true, memory: 16 << 30)
        #expect(l.map(\.title) == ["Gemma 4 E4B: not downloaded", "Download Gemma 4 E4B (5.4 GB)", "Use Qwen3.5-4B",
                                   "Download Qwen3.5-2B (1.7 GB)", "No On-Device Model", "Remove Downloaded Models"])
        #expect(l[1].action == .download(.gemma4e4b) && l[1].enabled)
        // a downloaded Gemma on a small Mac: only the models that fit, and Remove for the files
        let kept = StatusMenus.onDeviceLines(selected: .qwen4b, installed: [.gemma4e4b], progress: nil, mlxReady: true, memory: small)
        #expect(!kept.contains { $0.title.contains("Gemma") } && kept.last?.action == .remove && kept.last?.enabled == true)
    }

    /// The menu for each RAM size, with no model in use yet (the default).
    @Test func onDeviceMenuFollowsMemory() {
        var asked = 0
        func lines(_ gb: UInt64, installed: Set<MLXModelChoice> = []) -> [MenuLine] {
            StatusMenus.onDeviceLines(on: false, selected: MLXModelChoice.recommended(memory: gb << 30), installed: installed,
                                      progress: nil, mlxReady: { asked += 1; return true }(), memory: gb << 30)
        }
        let four = lines(4)
        #expect(four.map(\.title) == ["This Mac does not have enough memory for an on-device model. Search uses plain search."])
        #expect(four.allSatisfy { !$0.enabled } && asked == 0, "no download line, and no look for the MLX shaders")
        #expect(lines(4, installed: [.qwen2b]).map(\.action) == [.none, .remove])
        #expect(lines(8).map(\.title) == ["Not in use. Search does not use an on-device model.", "Download Qwen3.5-4B (3.1 GB)",
                                         "Download Qwen3.5-2B (1.7 GB)", "No On-Device Model", "Remove Downloaded Models"])
        for gb in [16, 32] as [UInt64] {
            let l = lines(gb)
            #expect(l.map(\.title) == ["Not in use. Search does not use an on-device model.", "Download Gemma 4 E4B (5.4 GB)",
                                      "Download Qwen3.5-4B (3.1 GB)", "Download Qwen3.5-2B (1.7 GB)", "No On-Device Model",
                                      "Remove Downloaded Models"], "\(gb) GB")
            #expect(l[4].checked && !l[4].enabled && l.dropLast().filter(\.checked).count == 1, "off is the checked line")
        }
    }

    /// An installed model that is not in use shows "Use"; when in use it is checked and "No On-Device Model" turns it off.
    @Test func onDeviceMenuOffAndOn() {
        let off = StatusMenus.onDeviceLines(on: false, selected: .qwen4b, installed: [.qwen4b], progress: nil, mlxReady: true, memory: 16 << 30)
        let use = off.first { $0.action == .use(.qwen4b) }
        #expect(use?.enabled == true && use?.checked == false)
        let on = StatusMenus.onDeviceLines(on: true, selected: .qwen4b, installed: [.qwen4b], progress: nil, mlxReady: true, memory: 16 << 30)
        #expect(on[0].title == "Qwen3.5-4B: downloaded")
        #expect(on.first { $0.action == .use(.qwen4b) }?.checked == true)
        let none = on.first { $0.action == .turnOff }
        #expect(none?.enabled == true && none?.checked == false)
    }

    @MainActor @Test func keyBoxSaysWhereTheKeyIs() {
        #expect(KeyBox.statusText(.shell, varName: "OPENAI_API_KEY").hasPrefix("Your shell sets OPENAI_API_KEY. Sanketa uses that key first."))
        #expect(KeyBox.statusText(.environment, varName: "MY_KEY").contains("only when MY_KEY is empty"))
        #expect(KeyBox.statusText(.keychain, varName: "OPENAI_API_KEY") == "Your Keychain has a key for this server. A new key replaces it.")
        #expect(KeyBox.statusText(nil, varName: "OPENAI_API_KEY") == "Sanketa found no key.")
    }

    @Test func throttleLetsOneCallThroughPerInterval() {
        let t = Throttle(60), t0 = Date()
        #expect(t.ready(now: t0) && !t.ready(now: t0 + 1) && !t.ready(now: t0 + 59))
        #expect(t.ready(now: t0 + 60) && !t.ready(now: t0 + 61))
    }
}
