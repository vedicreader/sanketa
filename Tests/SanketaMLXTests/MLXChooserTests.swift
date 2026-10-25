import Testing
import Foundation
import Darwin
@testable import SanketaMLX
import SanketaCore
import SanketaAI

private let packsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
private let bundled = PackLibrary.load(bundled: packsDir, user: nil).packs.values.sorted { $0.id < $1.id }
    .flatMap { SearchItem.items(from: $0) }
private let splitQuery = "how do I split the window side by side"

private func tempRoot() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-mlxchooser-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A chooser that is always available with the same picks.
private struct Fixed: Choosing {
    let name = "fixed", isRemote = false
    var picks: [String]
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] { picks }
}

/// A fake model: it answers `answer(prompt)` after `delay`, and records what it saw.
final class FakeRunner: PickRunner, @unchecked Sendable {
    let answer: @Sendable (ChoicePrompt) -> String
    let delay: Duration
    private let lock = NSLock()
    private var seen: [(schema: String, main: Bool)] = []
    private var cancelled = false, released = false
    init(delay: Duration = .zero, answer: @escaping @Sendable (ChoicePrompt) -> String) { self.delay = delay; self.answer = answer }

    func run(_ prompt: ChoicePrompt, schema: String) async throws -> String {
        lock.withLock { seen.append((schema, Thread.isMainThread)) }
        do { try await Task.sleep(for: delay) } catch { lock.withLock { cancelled = true }; throw error }
        return answer(prompt)
    }
    func release() { lock.withLock { released = true } }
    var calls: [(schema: String, main: Bool)] { lock.withLock { seen } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var wasReleased: Bool { lock.withLock { released } }
}

/// A chooser for `runner` in its own registry (or `registry`), so tests that run at once do not share models.
private func fakeChooser(_ runner: FakeRunner, idle: TimeInterval = 30, loads: Counts = Counts(), registry: Holders = Holders(),
                         key: String = UUID().uuidString, loadTime: Duration = .zero,
                         fail: Bool = false) -> MLXChooser {
    MLXChooser(name: "on-device (fake)", key: key, registry: registry, idle: idle, failedNote: "fake did not load",
               available: { .available }, load: {
                   _ = loads.loaded()
                   try await Task.sleep(for: loadTime)
                   if fail { throw ChoiceError.badResponse }
                   return runner
               })
}

/// A chooser with its model loaded.
private func loadedChooser(_ runner: FakeRunner, idle: TimeInterval = 30, loads: Counts = Counts()) async throws -> MLXChooser {
    let c = fakeChooser(runner, idle: idle, loads: loads)
    try await c.load()
    return c
}

private func router(_ c: any OnDeviceChooser, fm: (any Choosing)? = nil) -> ModelRouter {
    var config = LLMConfig()
    config.onDevice = true   // the user chose a model
    return ModelRouter(config: config, onDevice: c, appleFM: fm, remote: nil)
}

@Suite struct MLXChooserTests {
    @Test func notInstalledIsUnavailable() throws {
        let installer = ModelInstaller(root: try tempRoot())
        let c = MLXChooser(spec: ModelCatalog.gemma4e4b, installer: installer)
        #expect(c.name == "on-device (Gemma 4 E4B)")
        #expect(MLXChooser(spec: ModelCatalog.qwen2b, installer: installer).name == "on-device (Qwen3.5-2B)")
        #expect(c.status() == .unavailable("on-device model not downloaded"))
        #expect(router(c, fm: Fixed(picks: ["e1"])).searchChooser()?.name == "fixed")
    }

    /// `isInstalled` only checks sizes and the `.verified` mark, so small fake files of the pinned sizes do. The swift
    /// build has no metallib (`make test-mlx` has one, so there it checks only the status rule).
    @Test func missingMetallibIsUnavailable() throws {
        let spec = ModelSpec(choice: .qwen2b, repo: "test/tiny", revision: String(repeating: "a", count: 40), folder: "Tiny",
                             files: [ModelFile(name: "config.json", size: 3, sha256: String(repeating: "0", count: 64))])
        let installer = ModelInstaller(root: try tempRoot())
        let dir = installer.directory(spec)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("config.json"))
        try spec.revision.write(to: dir.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        #expect(installer.isInstalled(spec))
        let c = MLXChooser(spec: spec, installer: installer)
        if !MLXRuntime.isReady { #expect(c.status() == .unavailable("on-device model needs the app build")) }
        #expect(MLXChooser.status(installed: true, ready: false) == .unavailable("on-device model needs the app build"))
        #expect(MLXChooser.status(installed: true, ready: true) == .available)
        // a model that is not downloaded does not make the chooser look for the MLX shaders
        var asked = 0
        #expect(MLXChooser.status(installed: false, ready: { asked += 1; return true }()) == .unavailable("on-device model not downloaded"))
        #expect(asked == 0)
        #expect(router(c, fm: Fixed(picks: [])).searchChooser()?.name == (MLXRuntime.isReady ? c.name : "fixed"))
    }

    @Test func schemaLimitsPicksToRefs() throws {
        let s = MLXChooser.schema(refs: ["e1", "e2"], maxPicks: 3)
        let o = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        let picks = try #require((o["properties"] as? [String: Any])?["picks"] as? [String: Any])
        #expect((picks["items"] as? [String: Any])?["enum"] as? [String] == ["e1", "e2"])
        #expect(picks["maxItems"] as? Int == 3 && o["required"] as? [String] == ["picks"] && o["additionalProperties"] as? Bool == false)
    }

    @Test func answerParsingIsStrict() throws {
        #expect(try MLXChooser.picks(from: #"{"picks": ["e2", "e1"]}"#) == ["e2", "e1"])
        #expect(try MLXChooser.picks(from: #"{"picks": []}"#).isEmpty)
        for bad in ["e2", #"{"picks": "e2"}"#, #"{"picks": ["e2"], "why": "x"}"#, #"{"picks": ["e2"]"#, ""] {
            #expect(throws: ChoiceError.badResponse) { try MLXChooser.picks(from: bad) }
        }
    }

    @Test func fakeModelPicksThroughRouterAndLoadsOnce() async throws {
        let runner = FakeRunner { p in "{\"picks\": [\"\(p.refs[1])\", \"zz9\"]}" }
        let loads = Counts()
        let c = try await loadedChooser(runner, loads: loads)
        let s = SmartSearch(router: router(c), timeout: 5)
        let cands = Retrieval.candidates(splitQuery, bundled, context: ["tmux"])
        let r1 = await s.results(splitQuery, bundled, context: ["tmux"])
        _ = await s.results("show the git log as a graph", bundled, context: [])
        #expect(r1.note == nil)
        // the router keeps only known refs: ref 2 is the second candidate, "zz9" goes
        #expect(r1.picked == [cands[1].id] && r1.items.first?.id == cands[1].id)
        #expect(loads.loads == 1 && runner.calls.count == 2)
        #expect(runner.calls.allSatisfy { !$0.main })
        #expect(runner.calls[0].schema.contains("\"e1\"") && runner.calls[0].schema.contains("\"maxItems\":5"))
        #expect(await c.isLoaded)
    }

    @MainActor @Test func runsOffTheMainThread() async throws {
        let runner = FakeRunner { _ in #"{"picks": ["e1"]}"# }
        let p = ChoicePrompt(task: .search("a b c"), refs: ["e1"], lines: ["e1 | x | y | z"], maxPicks: 5)
        #expect(try await loadedChooser(runner).choose(p) == ["e1"])
        #expect(runner.calls.map(\.main) == [false])
    }

    @Test func emptyRefsSkipTheModel() async throws {
        let runner = FakeRunner { _ in "" }
        let loads = Counts()
        let p = ChoicePrompt(task: .search("a b c"), refs: [], lines: [], maxPicks: 5)
        #expect(try await fakeChooser(runner, loads: loads).choose(p).isEmpty)
        #expect(loads.loads == 0 && runner.calls.isEmpty)
    }

    @Test func badAnswerGivesPlainSearch() async throws {
        let r = await SmartSearch(router: router(try await loadedChooser(FakeRunner { _ in "e1, e2" })), timeout: 5)
            .results(splitQuery, bundled, context: ["tmux"])
        #expect(r.picked.isEmpty && !r.items.isEmpty)
        #expect(r.note == "Plain search: on-device (fake) failed")
    }

    @Test func timeoutCancelsTheRun() async throws {
        let runner = FakeRunner(delay: .seconds(5)) { _ in #"{"picks": ["e1"]}"# }
        let r = await SmartSearch(router: router(try await loadedChooser(runner)), timeout: 0.3).results(splitQuery, bundled, context: [])
        // the fake answers only after 5 s. The deadline runs on its own queue, but the result waits for a free pool
        // thread, so a full run can delay it: the proof is the timeout note and the cancelled run, not a wall clock
        #expect(r.note == "Plain search: on-device (fake) timed out")
        try await Task.sleep(for: .milliseconds(300))
        #expect(runner.wasCancelled, "the router stopped the run before its answer")
    }

    @Test func idleUnloadReleasesTheModel() async throws {
        let runner = FakeRunner { _ in #"{"picks": []}"# }
        let c = fakeChooser(runner, idle: 0.2)
        let clock = ContinuousClock(), t = clock.now
        c.prewarm()
        while await !c.isLoaded, !runner.wasReleased, clock.now - t < .seconds(2) { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await c.isLoaded || runner.wasReleased)
        while await c.isLoaded, clock.now - t < .seconds(3) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await !c.isLoaded)
        #expect(runner.wasReleased)
    }

    @Test func searchDuringLoadIsPlainAndTheNextUsesTheModel() async throws {
        let runner = FakeRunner { p in "{\"picks\": [\"\(p.refs[0])\"]}" }
        let loads = Counts()
        let c = fakeChooser(runner, loads: loads, loadTime: .seconds(2))
        let s = SmartSearch(router: router(c), timeout: 5)
        let clock = ContinuousClock(), t = clock.now
        let first = await s.results(splitQuery, bundled, context: ["tmux"])
        // it did not wait for the 2 s load
        #expect(await !c.isLoaded)
        #expect(first.picked.isEmpty && !first.items.isEmpty)
        #expect(first.note == "Plain search: on-device (fake) is loading")
        // a second search during the load does not start a second load
        _ = await s.results(splitQuery, bundled, context: ["tmux"])
        while await !c.isLoaded, clock.now - t < .seconds(15) { try await Task.sleep(for: .milliseconds(50)) }
        let next = await s.results(splitQuery, bundled, context: ["tmux"])
        #expect(next.note == nil && next.picked.count == 1)
        #expect(loads.loads == 1 && runner.calls.count == 1)
    }

    @Test func modelSwitchUnloadsThePreviousModel() async throws {
        let registry = Holders()
        let a = FakeRunner { _ in #"{"picks": []}"# }, b = FakeRunner { _ in #"{"picks": []}"# }
        let first = fakeChooser(a, registry: registry, key: "a")
        try await first.load()
        #expect(await first.isLoaded)
        let second = fakeChooser(b, registry: registry, key: "b")
        try await second.load()
        #expect(a.wasReleased && !b.wasReleased)
        let (firstIn, secondIn) = (await first.isLoaded, await second.isLoaded)
        #expect(!firstIn && secondIn)
        // the same folder gives the same holder, so its model is not loaded twice
        #expect(await fakeChooser(b, registry: registry, key: "b").isLoaded)
    }

    @Test func unloadAllFreesTheModel() async throws {
        let registry = Holders()
        let runner = FakeRunner { _ in #"{"picks": []}"# }
        let c = fakeChooser(runner, registry: registry)
        try await c.load()
        await registry.dropOthers(nil)
        #expect(await !c.isLoaded && runner.wasReleased)
    }

    @Test func modelThatDoesNotLoadSaysSo() async throws {
        let c = fakeChooser(FakeRunner { _ in "" }, fail: true)
        #expect(c.status() == .available)
        await #expect(throws: ChoiceError.badResponse) { try await c.load() }
        #expect(c.status() == .unavailable("fake did not load"))
        // the router goes on to the next tier, and its note says why the first one is off
        #expect(router(c, fm: Fixed(picks: [])).searchChooser()?.name == "fixed")
        #expect(MLXChooser.failedNote(.gemma4e4b) == "Gemma 4 E4B did not load; choose Qwen3.5-4B 6-bit in the On-Device Model menu")
        #expect(MLXChooser.failedNote(.qwen4b) == "Qwen3.5-4B did not load")
    }

    /// A model that did not load (low memory, a bad file) gets a new try after Remove and a new download.
    @Test func modelThatDidNotLoadIsTriedAgainAfterNewFiles() async throws {
        let registry = Holders(), loads = Counts(), runner = FakeRunner { _ in #"{"picks": []}"# }
        let c = MLXChooser(name: "on-device (fake)", key: "m", registry: registry, idle: 30, failedNote: "fake did not load",
                           available: { .available }, load: {
                               if loads.loaded() == 1 { throw ChoiceError.badResponse }
                               return runner
                           })
        await #expect(throws: ChoiceError.badResponse) { try await c.load() }
        #expect(c.status() == .unavailable("fake did not load"))
        registry.forgetFailure("other")
        #expect(c.status() == .unavailable("fake did not load"), "another model's new files change nothing")
        registry.forgetFailure("m")                   // what a download of this model does
        #expect(c.status() == .available)
        try await c.load()
        #expect(loads.loads == 2 && c.status() == .available)
        #expect(await c.isLoaded)

        let other = Holders(), d = fakeChooser(FakeRunner { _ in "" }, registry: other, fail: true)
        await #expect(throws: ChoiceError.badResponse) { try await d.load() }
        other.forgetFailure(nil)                      // what Remove does
        #expect(d.status() == .available)
    }

    @Test func modelFolderMustHoldOnlyFiles() throws {
        let d = try tempRoot()
        try Data("{}".utf8).write(to: d.appendingPathComponent("config.json"))
        try ModelFolder.check(d)
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link.json"),
                                                   withDestinationURL: d.appendingPathComponent("config.json"))
        #expect(throws: ModelFolder.Problem.notData("link.json")) { try ModelFolder.check(d) }
    }
}

// MARK: live, with the downloaded model (make test-mlx)

enum MLXGate {
    static let spec = ModelCatalog.spec(.gemma4e4b)
    static let installer = ModelInstaller(root: ModelCatalog.defaultRoot)
    static var ready: Bool { installer.isInstalled(spec) && MLXRuntime.isReady }
}

/// This process's memory footprint (what Activity Monitor shows) in bytes.
private func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n) }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

/// This process's CPU use in percent of one core over `seconds`.
private func cpuPercent(over seconds: Double) async throws -> Double {
    func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    let a = cpu()
    try await Task.sleep(for: .seconds(seconds))
    return (cpu() - a) / seconds * 100
}

private func gb(_ b: some BinaryInteger) -> String { String(format: "%.2f GB", Double(b) / 1e9) }

/// The first 3 search queries of the bench, with the (pack, title) of their gold entries; built-in ones without it.
private func evalQueries() -> [(query: String, gold: [(String, String)])] {
    struct Eval: Decodable {
        struct Entry: Decodable { let id, pack, title: String }
        struct Query: Decodable { let query: String; let gold: [String] }
        let entries: [Entry]; let search: [Query]
    }
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/sanketa-bench/eval.json")),
          let e = try? JSONDecoder().decode(Eval.self, from: d) else {
        return [("how do I find which process eats memory", [("htop", "Sort by memory")]),
                ("split the screen into top and bottom halves", [("tmux", "Split pane top/bottom")]),
                ("show the commit history as a graph", [("git", "Log graph")])]
    }
    let byID = Dictionary(e.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return e.search.prefix(3).map { q in (q.query, q.gold.compactMap { byID[$0].map { ($0.pack, $0.title) } }) }
}

private func hits(_ item: SearchItem, _ gold: [(String, String)]) -> Bool {
    gold.contains { p, t in
        let a = item.title.lowercased(), b = t.lowercased()
        return item.packID == p && (a.hasPrefix(b) || b.hasPrefix(a))
    }
}

@Suite(.serialized) struct MLXChooserLiveTests {
    @Test(.enabled(if: MLXGate.ready), .timeLimit(.minutes(6))) func liveSearchIsGroundedAndUnloadsAfterIdle() async throws {
        let dir = MLXGate.installer.directory(MLXGate.spec)
        try ModelFolder.check(dir)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let q = getxattr(dir.appendingPathComponent(name).path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW)
            print("live MLX: \(name) quarantine xattr: \(q >= 0 ? "present" : "none")")
            #expect(q < 0, "\(name) has a quarantine attribute")
        }
        let idle: TimeInterval = 60
        let c = MLXChooser(spec: MLXGate.spec, installer: MLXGate.installer, idle: idle)
        #expect(c.status() == .available)
        let s = SmartSearch(router: router(c), timeout: 90)
        let base = footprint()
        let clock = ContinuousClock()

        func run(_ q: String, _ ctx: [String]) async -> (SmartResult, Duration) {
            let t = clock.now
            let r = await s.results(q, bundled, context: ctx)
            let took = clock.now - t
            print("live MLX: \"\(q)\" took \(took), picked \(r.items.filter { r.picked.contains($0.id) }.map { "\($0.packID): \($0.title)" }), note \(r.note ?? "-")")
            #expect(r.note == nil)
            #expect(r.picked.isSubset(of: Set(Retrieval.candidates(q, bundled, context: ctx).map(\.id))))
            return (r, took)
        }

        // a search before the model is in memory is plain at once and starts the load
        let t0 = clock.now
        let early = await s.results(splitQuery, bundled, context: ["tmux"])
        print("live MLX: search during load took \(clock.now - t0), note \(early.note ?? "-")")
        #expect(early.note == "Plain search: \(c.name) is loading" && early.picked.isEmpty && clock.now - t0 < .seconds(1))
        do { try await c.load() } catch {
            Issue.record("\(MLXGate.spec.folder) did not load in mlx-swift-lm: \(error)")
            #expect(c.status() == .unavailable(MLXChooser.failedNote(MLXGate.spec.choice)))
            return
        }
        let loadTime = clock.now - t0
        // the first query after the load (the grammar compiles for the first time)
        let (split, cold) = await run(splitQuery, ["tmux"])
        #expect(!split.picked.isEmpty)
        #expect(split.items.prefix(3).contains { $0.packID == "tmux" && $0.title.lowercased().contains("split") })
        let (none, _) = await run("bake sourdough bread at home tonight", [])
        #expect(none.picked.isEmpty)
        var warm: [Duration] = [], gold = 0
        let evals = evalQueries()
        for e in evals {
            let (r, took) = await run(e.query, [])
            warm.append(took)
            #expect(!r.picked.isEmpty)
            if r.items.prefix(3).contains(where: { hits($0, e.gold) }) { gold += 1 }
        }
        let median = warm.sorted()[warm.count / 2]
        print("live MLX: load \(loadTime), first query \(cold), warm median \(median) of \(warm), gold in top 3: \(gold)/\(evals.count)")
        #expect(cold < .seconds(60) && median < .seconds(10))

        let loaded = footprint()
        #expect(await c.isLoaded)
        let busyIdle = try await cpuPercent(over: 10)
        #expect(await c.isLoaded)
        print("live MLX: loaded: footprint \(gb(loaded)) (before \(gb(base))), MLX active \(gb(MLXRuntime.memory.active)), cache \(gb(MLXRuntime.memory.cache)), peak \(gb(MLXRuntime.memory.peak)); idle CPU \(String(format: "%.2f", busyIdle)) %")

        let t = clock.now
        while await c.isLoaded, clock.now - t < .seconds(idle + 10) { try await Task.sleep(for: .milliseconds(250)) }
        #expect(await !c.isLoaded)
        print("live MLX: unloaded after \(clock.now - t) more")
        try await Task.sleep(for: .seconds(1))
        let after = footprint(), freeIdle = try await cpuPercent(over: 3)
        print("live MLX: unloaded: footprint \(gb(after)), MLX active \(gb(MLXRuntime.memory.active)), cache \(gb(MLXRuntime.memory.cache)); idle CPU \(String(format: "%.2f", freeIdle)) %")
        #expect(MLXRuntime.memory.active < 500_000_000)
        #expect(after < loaded)
    }
}
