import Testing
import Foundation
@testable import SanketaAI
import SanketaCore

private let modelsPath = "/v1/models"
private let chatPath = "/v1/chat/completions"
private let modelsReply = #"{"data":[{"id":"gpt-4.1"},{"id":"gpt-4o-mini"},{"id":"gpt-5-nano"},{"id":"whisper-1"}]}"#
private let okReply = #"{"choices":[{"message":{"role":"assistant","content":"{\"picks\":[\"e1\"]}"}}]}"#
private let items = [
    SearchItem(packID: "tmux", packName: "tmux", kind: .key, title: "Split pane left/right", detail: "prefix %", mayLeave: true),
    SearchItem(packID: "tmux", packName: "tmux", kind: .key, title: "Split pane top/bottom", detail: "prefix \"", mayLeave: true),
]

/// A clock that tests move by hand.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

private actor Counter {
    var n = 0
    func bump() -> Int { n += 1; return n }
}

private func llm(openai: Bool = true, model: String = "") -> LLMConfig {
    var c = LLMConfig()
    c.openai = openai; c.openaiModel = model; c.onDevice = false; c.appleFM = false
    return c
}

private func setup(_ stub: Stub, _ c: LLMConfig, previous: LLMSetup? = nil, env: [String: String] = ["OPENAI_API_KEY": "sk-test"]) -> LLMSetup {
    LLMSetup(config: c, previous: previous, makeKeys: {
        KeyLookup(varName: c.apiKeyEnv, env: env, shell: nil, runner: ProcessRunner(), store: MemoryKeyStore(), account: $0)
    }, session: stub.session, onDevice: nil, appleFM: nil)
}

@Suite struct LLMSetupTests {
    @Test func searchesShareOneModelListRequest() async throws {
        let stub = Stub([modelsPath: [(200, modelsReply)], chatPath: [(200, okReply)]])
        let s = setup(stub, llm())
        let r = SmartSearch(router: s.router, timeout: 10)
        for q in ["split the pane side by side", "split the pane top and bottom", "how do I split panes"] {
            let res = await r.results(q, items, context: [])
            #expect(res.note == nil, "\(res.note ?? "")")
        }
        #expect(stub.requests.filter { $0.url?.path == modelsPath }.count == 1)
        let posts = stub.requests.filter { $0.url?.path == chatPath }
        #expect(posts.count == 3)
        #expect(posts.allSatisfy { $0.json?["model"] as? String == "gpt-5-nano" })
        #expect(await s.models?.cached == ["gpt-4.1", "gpt-4o-mini", "gpt-5-nano"])
    }

    @Test func pinnedModelNeedsNoList() async throws {
        let stub = Stub([chatPath: [(200, okReply)]])
        let s = setup(stub, llm(model: "gpt-4.1"))
        _ = await SmartSearch(router: s.router, timeout: 10).results("split the pane side by side", items, context: [])
        #expect(stub.requests.map { $0.url?.path } == [chatPath])
        #expect(stub.requests.first?.json?["model"] as? String == "gpt-4.1")
    }

    @Test func cacheRefetchesAfterTTLAndOnRefresh() async throws {
        let clock = Clock(), count = Counter()
        let cache = ModelListCache(ttl: 600, failureTTL: 60, now: { clock.now }) { _ = await count.bump(); return ["gpt-5-nano"] }
        #expect(await cache.cached == nil)
        _ = try await cache.models()
        clock.advance(599)
        _ = try await cache.models()
        #expect(await count.n == 1)
        clock.advance(2)
        _ = try await cache.models()
        #expect(await count.n == 2)
        _ = try await cache.refresh()
        #expect(await count.n == 3)
        #expect(await cache.cheapest() == "gpt-5-nano")
        #expect(await count.n == 3)
    }

    @Test func failedListIsNotAskedAgainAtOnce() async throws {
        let clock = Clock(), count = Counter()
        let cache = ModelListCache(ttl: 600, failureTTL: 60, now: { clock.now }) { _ = await count.bump(); throw ChoiceError.http(401) }
        for _ in 0..<3 { #expect(await cache.cheapest() == nil) }
        #expect(await count.n == 1)
        clock.advance(61)
        #expect(await cache.cheapest() == nil)
        #expect(await count.n == 2)
    }

    @Test func concurrentCallsShareOneFetch() async throws {
        let count = Counter()
        let cache = ModelListCache { _ = await count.bump(); try await Task.sleep(for: .milliseconds(200)); return ["a"] }
        async let a = cache.models(), b = cache.models(), c = cache.refresh()
        #expect(try await [a, b, c] == [["a"], ["a"], ["a"]])
        #expect(await count.n == 1)
    }

    @Test func noKeyGivesNoteWithoutRequest() async throws {
        let stub = Stub([modelsPath: [(200, modelsReply)], chatPath: [(200, okReply)]])
        let s = setup(stub, llm(), env: [:])
        let r = await SmartSearch(router: s.router, timeout: 10).results("split the pane side by side", items, context: [])
        #expect(r.note == "Plain search: OpenAI no key")
        // the model menu asks for the list: no request goes out without a key
        await #expect(throws: ChoiceError.noKey) { try await s.models?.refresh() }
        #expect(stub.requests.isEmpty)
    }

    @Test func reloadKeepsLookupAndCacheForSameServer() throws {
        let stub = Stub([:])
        let a = setup(stub, llm())
        var c = llm(model: "gpt-4.1")
        let b = setup(stub, c, previous: a)
        #expect(b.keys === a.keys && b.models === a.models)
        c.baseURL = "https://llm.example.com/v1"
        let d = setup(stub, c, previous: b)
        #expect(d.keys !== a.keys && d.providerName == "llm.example.com" && a.providerName == "OpenAI")
        #expect(d.router.remote?.name == "llm.example.com")
        #expect(setup(stub, llm(openai: false)).router.remote == nil)
    }
}
