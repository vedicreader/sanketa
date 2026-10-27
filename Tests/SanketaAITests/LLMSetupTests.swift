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

private func setup(_ stub: Stub, _ c: LLMConfig, previous: LLMSetup? = nil, env: [String: String] = ["OPENAI_API_KEY": "sk-test"],
                   store: KeyStore = MemoryKeyStore()) -> LLMSetup {
    LLMSetup(config: c, previous: previous, makeKeys: {
        KeyLookup(varName: $1, env: env, shell: nil, runner: ProcessRunner(), store: store, account: $0)
    }, session: stub.session, onDevice: nil, appleFM: nil)
}

private let openRouter = "https://openrouter.ai/api/v1", local = "http://localhost:1234/v1"

/// One search against `base` with a pinned model; the chat requests that went out and the note.
private func search(_ base: String, apiKeyEnv: String? = nil, env: [String: String] = ["OPENAI_API_KEY": "sk-openai"],
                    store: KeyStore = MemoryKeyStore()) async -> (posts: [StubRequest], note: String?) {
    let stub = Stub(["/v1/chat/completions": [(200, okReply)], "/api/v1/chat/completions": [(200, okReply)]])
    var c = llm(model: "m")
    c.baseURL = base; c.apiKeyEnv = apiKeyEnv
    let r = await SmartSearch(router: setup(stub, c, env: env, store: store).router, timeout: 60)
        .results("split the pane side by side", items, context: [])
    return (stub.requests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }, r.note)
}

@Suite struct LLMSetupTests {
    /// The default config makes no on-device chooser at all, so the MLX runtime never starts; a chosen model does.
    @Test func onDeviceChooserIsMadeOnlyWhenOn() {
        final class Made: @unchecked Sendable { var n = 0 }
        struct Fake: OnDeviceChooser {
            var name: String { "fake" }
            func status() -> ModelStatus { .available }
            func choose(_ prompt: ChoicePrompt) async throws -> [String] { [] }
        }
        let made = Made()
        func make() -> (any OnDeviceChooser)? { made.n += 1; return Fake() }
        let keys = { (a: String, v: String?) in KeyLookup(varName: v, env: [:], shell: nil, runner: ProcessRunner(), store: MemoryKeyStore(), account: a) }
        let off = LLMSetup(config: LLMConfig(), makeKeys: keys, onDevice: make(), appleFM: nil)
        #expect(made.n == 0 && off.router.onDevice == nil && !LLMConfig().onDevice)
        var on = LLMConfig()
        on.onDevice = true
        let used = LLMSetup(config: on, makeKeys: keys, onDevice: make(), appleFM: nil)
        #expect(made.n == 1 && used.router.searchChooser()?.name == "fake")
    }

    @Test func searchesShareOneModelListRequest() async throws {
        let stub = Stub([modelsPath: [(200, modelsReply)], chatPath: [(200, okReply)]])
        let s = setup(stub, llm())
        let r = SmartSearch(router: s.router, timeout: 60)
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
        _ = await SmartSearch(router: s.router, timeout: 60).results("split the pane side by side", items, context: [])
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

    @Test func envKeyGoesOnlyToOpenAI() async throws {
        let openAI = await search("https://api.openai.com/v1")
        #expect(openAI.posts.count == 1 && openAI.posts.first?.header("Authorization") == "Bearer sk-openai")
        // another server gets no OPENAI_API_KEY: no key, so no request
        let other = await search(openRouter)
        #expect(other.posts.isEmpty && other.note == "Plain search: openrouter.ai no key", "\(other.note ?? "")")
        // a server on this Mac needs no key, and it gets no header
        let mac = await search(local)
        #expect(mac.posts.count == 1 && mac.posts.first?.header("Authorization") == nil)
    }

    @Test func apiKeyEnvSendsThatVariable() async throws {
        let env = ["OPENAI_API_KEY": "sk-openai", "OPENROUTER_API_KEY": "sk-router"]
        let r = await search(openRouter, apiKeyEnv: "OPENROUTER_API_KEY", env: env)
        #expect(r.posts.count == 1 && r.posts.first?.header("Authorization") == "Bearer sk-router")
        let mac = await search(local, apiKeyEnv: "OPENROUTER_API_KEY", env: env)
        #expect(mac.posts.first?.header("Authorization") == "Bearer sk-router")
    }

    @Test func keychainKeyGoesOnlyToItsHost() async throws {
        let store = MemoryKeyStore()
        try store.write("sk-saved-router", account: "openrouter.ai")
        let r = await search(openRouter, store: store)
        #expect(r.posts.count == 1 && r.posts.first?.header("Authorization") == "Bearer sk-saved-router")
        let mac = await search(local, store: store)
        #expect(mac.posts.count == 1 && mac.posts.first?.header("Authorization") == nil)
        let openAI = await search("https://api.openai.com/v1", env: [:], store: store)
        #expect(openAI.posts.isEmpty)
    }

    @Test func noKeyGivesNoteWithoutRequest() async throws {
        let stub = Stub([modelsPath: [(200, modelsReply)], chatPath: [(200, okReply)]])
        let s = setup(stub, llm(), env: [:])
        let r = await SmartSearch(router: s.router, timeout: 60).results("split the pane side by side", items, context: [])
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

    /// Make a Pack uses the same key lookup and model choice as search, and nothing while Use OpenAI is off.
    @Test func packMakerSenderFollowsTheConfig() async throws {
        let stub = Stub([modelsPath: [(200, modelsReply)],
                         "/v1/responses": [(200, #"{"output":[{"type":"message","content":[{"type":"output_text","text":"id = \"x\""}]}]}"#)]])
        #expect(setup(stub, llm(openai: false)).packMaker() == nil)
        let s = try #require(setup(stub, llm()).packMaker())
        #expect(try await s.send("p") == "id = \"x\"")
        _ = try await setup(stub, llm(model: "gpt-4.1")).packMaker()?.send("p")
        let models = stub.requests.filter { $0.url?.path == "/v1/responses" }.compactMap { $0.json?["model"] as? String }
        #expect(models == ["gpt-5-nano", "gpt-4.1"])
        #expect(stub.requests.allSatisfy { $0.header("Authorization") == "Bearer sk-test" })
    }
}
