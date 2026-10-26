import Testing
import Foundation
import FoundationModels
@testable import SanketaAI
import SanketaCore

private let packsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
private let library = PackLibrary.load(bundled: packsDir, user: nil)
private let bundled = library.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
private let fmOn = SystemLanguageModel.default.isAvailable

private func fmRouter(_ fm: any Choosing) -> ModelRouter { ModelRouter(config: LLMConfig(), onDevice: nil, appleFM: fm, remote: nil) }

/// Runs a live search through the router and gives the result with the time it took.
private func liveSearch(_ query: String, context: [String]) async -> (SmartResult, Duration) {
    let fm = AppleFMChooser()
    fm.prewarm()
    let clock = ContinuousClock(), t = clock.now
    let r = await SmartSearch(router: fmRouter(fm), timeout: 15).results(query, bundled, context: context)
    let took = clock.now - t
    print("live FM: \"\(query)\" took \(took), picked \(r.items.filter { r.picked.contains($0.id) }.map(\.title)), note \(r.note ?? "-")")
    return (r, took)
}

@Suite struct AppleFMChooserTests {
    @Test func schemaAcceptsRefs() throws {
        let schema = try AppleFMChooser.schema(refs: ["e1", "e2", "e3"], maxPicks: 3)
        let json = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)
        #expect(json.range(of: #""maxItems"\s*:\s*3"#, options: .regularExpression) != nil)
        for ref in ["e1", "e2", "e3"] { #expect(json.contains("\"\(ref)\"")) }
    }

    @Test func statusNamesEachReason() {
        let cases: [(SystemLanguageModel.Availability, ModelStatus)] = [
            (.available, .available),
            (.unavailable(.deviceNotEligible), .unavailable("this Mac cannot run Apple Intelligence")),
            (.unavailable(.appleIntelligenceNotEnabled), .unavailable("Apple Intelligence is off")),
            (.unavailable(.modelNotReady), .unavailable("Apple Intelligence model not ready")),
        ]
        for (a, s) in cases { #expect(AppleFMChooser(availability: { a }).status() == s) }
    }

    @Test func offFMDegradesWithoutCall() async {
        let fm = AppleFMChooser(availability: { .unavailable(.appleIntelligenceNotEnabled) })
        fm.prewarm()
        let r = await SmartSearch(router: fmRouter(fm), timeout: 2)
            .results("how do I split the window side by side", bundled, context: ["tmux"])
        #expect(!r.items.isEmpty)
        #expect(r.picked.isEmpty)
        #expect(r.note?.hasPrefix("Plain search:") == true)
        #expect(r.note?.contains("Apple Intelligence is off") == true)
    }

    @Test func guardrailAndRefusalAreNotAllowed() async {
        typealias E = LanguageModelSession.GenerationError
        let ctx = E.Context(debugDescription: "test")
        #expect(AppleFMChooser.mapped(E.guardrailViolation(ctx)) as? ChoiceError == .notAllowed)
        #expect(AppleFMChooser.mapped(E.refusal(E.Refusal(transcriptEntries: []), ctx)) as? ChoiceError == .notAllowed)
        #expect(AppleFMChooser.mapped(E.exceededContextWindowSize(ctx)) as? ChoiceError == .contextExceeded)
        #expect(AppleFMChooser.mapped(E.rateLimited(ctx)) as? ChoiceError == nil)
        // the user sees one muted note that names the reason
        struct Refusing: Choosing {
            let name = "Apple Intelligence", isRemote = false
            func status() -> ModelStatus { .available }
            func choose(_ p: ChoicePrompt) async throws -> [String] { throw AppleFMChooser.mapped(E.guardrailViolation(.init(debugDescription: ""))) }
        }
        let r = await SmartSearch(router: fmRouter(Refusing()), timeout: 5).results("how do I split the window side by side", bundled, context: [])
        #expect(r.note == "Plain search: Apple Intelligence refused the request")
    }

    @Test func emptyRefsGiveNoPicks() async throws {
        let p = ChoicePrompt(task: .search("anything at all"), refs: [], lines: [], maxPicks: 5)
        #expect(try await AppleFMChooser(availability: { .available }).choose(p).isEmpty)
    }

    @Test(.disabled(if: fmOn)) func unavailableFMDegrades() async {
        let r = await SmartSearch(router: fmRouter(AppleFMChooser()), timeout: 2)
            .results("how do I split the window side by side", bundled, context: ["tmux"])
        #expect(!r.items.isEmpty)
        #expect(r.picked.isEmpty)
        #expect(r.note?.hasPrefix("Plain search:") == true)
    }

    @Test(.enabled(if: fmOn), .timeLimit(.minutes(1))) func liveSearchPicksSplit() async {
        let query = "how do I split the window side by side"
        let (r, took) = await liveSearch(query, context: ["tmux"])
        let cands = Set(Retrieval.candidates(query, bundled, context: ["tmux"]).map(\.id))
        #expect(r.note == nil)
        #expect(!r.picked.isEmpty)
        #expect(r.picked.isSubset(of: cands))
        #expect(r.items.prefix(3).contains { $0.packID == "tmux" && $0.title.lowercased().contains("split") })
        #expect(took < .seconds(15))
    }

    @Test(.enabled(if: fmOn), .timeLimit(.minutes(1))) func liveNoMatchStaysGrounded() async {
        let query = "bake sourdough bread at home tonight"
        let (r, took) = await liveSearch(query, context: [])
        let cands = Set(Retrieval.candidates(query, bundled, context: []).map(\.id))
        #expect(r.picked.isSubset(of: cands))
        #expect(r.picked.count <= SmartSearch.maxPicks)
        #expect(took < .seconds(15))
    }

    @Test(.enabled(if: fmOn), .timeLimit(.minutes(1))) func liveSuggestPicksFromRecentPacks() async {
        let recent = ["git log --oneline | head -n 20", "git status"].map { HistoryEntry(command: $0, shell: .fish) }
        let cands = SmartSuggest.candidates(recent: recent, library: library, items: bundled, excluding: [])
        let clock = ContinuousClock(), t = clock.now
        let got = await SmartSuggest.pick(recent: recent, library: library, items: bundled, excluding: [],
                                          router: fmRouter(AppleFMChooser()), timeout: 15)
        print("live FM suggest took \(clock.now - t), picked \(got.map(\.title))")
        #expect(!cands.isEmpty)
        #expect(got.count <= SmartSuggest.maxPicks)
        #expect(Set(got.map(\.id)).isSubset(of: Set(cands.map(\.id))))
        #expect(clock.now - t < .seconds(15))
    }
}
