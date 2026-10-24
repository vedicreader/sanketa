import Testing
import Foundation
@testable import SanketaAI
import SanketaCore

private let openAI = URL(string: "https://api.openai.com/v1")!
private let chatPath = "/v1/chat/completions"
private let okReply = #"{"choices":[{"message":{"role":"assistant","content":"{\"picks\":[\"e2\",\"e1\"]}"}}]}"#
private let items = [
    SearchItem(packID: "tmux", packName: "tmux", kind: .key, title: "Split pane left/right", detail: "prefix %"),
    SearchItem(packID: "tmux", packName: "tmux", kind: .key, title: "Split pane top/bottom", detail: "prefix \""),
    SearchItem(packID: "vim", packName: "Vim", kind: .key, title: "Split window", detail: ":vsplit"),
]
private let prompt = ChoicePrompt.build(task: .search("split the pane side by side"), candidates: items, maxPicks: 5).prompt

private func chooser(_ stub: Stub, base: URL = openAI, model: String? = "gpt-4o-mini", key: String? = "sk-test") -> OpenAIChooser {
    OpenAIChooser(baseURL: base, model: { model }, key: { key }, session: stub.session, timeout: 30)
}

private func choiceError(_ body: () async throws -> [String]) async -> ChoiceError? {
    do { _ = try await body(); return nil } catch let e as ChoiceError { return e } catch { return nil }
}

@Suite struct OpenAIChooserTests {
    @Test func chooserSendsRequestAndParses() async throws {
        let stub = Stub([chatPath: [(200, okReply)]])
        let c = chooser(stub)
        #expect(c.name == "OpenAI" && c.isRemote && c.status() == .available)
        #expect(try await c.choose(prompt) == ["e2", "e1"])
        let r = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(r.method == "POST")
        #expect(r.header("Authorization") == "Bearer sk-test")
        #expect(r.header("Content-Type") == "application/json")
        #expect(r.timeout == 30)
        #expect(r.body == OpenAIRequest.body(model: "gpt-4o-mini", prompt: prompt, openAI: true))
    }

    @Test func localServerNeedsNoKey() async throws {
        let stub = Stub(["/v1/chat/completions": [(200, okReply)]])
        let c = chooser(stub, base: URL(string: "http://localhost:11434/v1")!, model: "llama3.2", key: nil)
        #expect(c.name == "localhost")
        #expect(try await c.choose(prompt) == ["e2", "e1"])
        let r = try #require(stub.requests.first)
        #expect(r.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(r.header("Authorization") == nil)
        #expect(r.json?["max_tokens"] as? Int == 100 && r.json?["store"] == nil)
    }

    @Test func noKeyThrowsForOpenAI() async {
        let stub = Stub([chatPath: [(200, okReply)]])
        #expect(await choiceError { try await chooser(stub, key: nil).choose(prompt) } == .noKey)
        #expect(await choiceError { try await chooser(stub, key: "").choose(prompt) } == .noKey)
        #expect(stub.requests.isEmpty)
    }

    @Test func noModelIsBadResponse() async {
        let stub = Stub([chatPath: [(200, okReply)]])
        #expect(await choiceError { try await chooser(stub, model: nil).choose(prompt) } == .badResponse)
        #expect(stub.requests.isEmpty)
    }

    @Test func http401FallsBackWithNote() async {
        let stub = Stub([chatPath: [(401, #"{"error":{"message":"bad key"}}"#)]])
        #expect(await choiceError { try await chooser(stub).choose(prompt) } == .http(401))
        #expect(stub.requests.count == 1)

        var cfg = LLMConfig(); cfg.onDevice = false; cfg.appleFM = false; cfg.openai = true
        let router = ModelRouter(config: cfg, onDevice: nil, appleFM: nil, remote: chooser(stub))
        let query = "split the pane side by side"
        let r = await SmartSearch(router: router, timeout: 60).results(query, items, context: ["tmux"])
        #expect(r.items == Retrieval.candidates(query, items, context: ["tmux"]))
        #expect(r.picked.isEmpty)
        #expect(r.note?.contains("OpenAI") == true && r.note?.contains("401") == true)
    }

    @Test func openAI400IsNotRetried() async {
        let stub = Stub([chatPath: [(400, "{}"), (200, okReply)]])
        #expect(await choiceError { try await chooser(stub).choose(prompt) } == .http(400))
        #expect(stub.requests.count == 1)
    }

    @Test func custom400RetriesWithoutSchema() async throws {
        let stub = Stub([chatPath: [(400, #"{"error":"response_format not supported"}"#), (200, okReply)]])
        let c = chooser(stub, base: URL(string: "http://localhost:1234/v1")!, model: "qwen3:4b", key: nil)
        #expect(try await c.choose(prompt) == ["e2", "e1"])
        let reqs = stub.requests
        #expect(reqs.count == 2)
        #expect(reqs[0].json?["response_format"] != nil)
        #expect(reqs[1].json?["response_format"] == nil)
        #expect(reqs[1].json?["model"] as? String == "qwen3:4b")
    }

    @Test func suggestIsRefused() async {
        let stub = Stub([chatPath: [(200, okReply)]])
        let p = ChoicePrompt.build(task: .suggest(["git status"]), candidates: items, maxPicks: 2).prompt
        #expect(await choiceError { try await chooser(stub).choose(p) } == .notAllowed)
        #expect(stub.requests.isEmpty)
    }

    @Test func modelListFetchesAndFilters() async throws {
        let stub = Stub(["/v1/models": [(200, #"{"object":"list","data":[{"id":"gpt-5-nano"},{"id":"whisper-1"}]}"#)]])
        #expect(try await ModelList.fetch(baseURL: openAI, key: "sk-test", session: stub.session) == ["gpt-5-nano"])
        let r = try #require(stub.requests.first)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(r.method == "GET")
        #expect(r.header("Authorization") == "Bearer sk-test")
    }

    @Test func modelListKeepsOtherServersIdsAndReportsHTTP() async throws {
        let base = URL(string: "http://127.0.0.1:1234/v1")!
        let ok = Stub(["/v1/models": [(200, #"{"data":[{"id":"qwen3:4b"},{"id":"llama3.2"}]}"#)]])
        #expect(try await ModelList.fetch(baseURL: base, key: nil, session: ok.session) == ["llama3.2", "qwen3:4b"])
        #expect(ok.requests.first?.header("Authorization") == nil)

        let denied = Stub(["/v1/models": [(401, "{}")]])
        await #expect(throws: ChoiceError.http(401)) { try await ModelList.fetch(baseURL: openAI, key: "sk-x", session: denied.session) }
        let garbage = Stub(["/v1/models": [(200, "oops")]])
        await #expect(throws: ChoiceError.badResponse) { try await ModelList.fetch(baseURL: openAI, key: "sk-x", session: garbage.session) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SANKETA_LIVE_OPENAI"] == "1"))
    func liveOpenAIPicksOnlyCandidates() async throws {
        let packsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
        let library = PackLibrary.load(bundled: packsDir, user: nil)
        let bundled = library.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        let model = try #require(OpenAIModels.cheapest(try await ModelList.fetch(baseURL: openAI, key: key)))
        let query = "how do I split the window side by side"
        let cands = Retrieval.candidates(query, bundled, context: ["tmux"])
        let p = ChoicePrompt.build(task: .search(query), candidates: cands, maxPicks: SmartSearch.maxPicks).prompt
        let picks = try await OpenAIChooser(baseURL: openAI, model: { model }, key: { key }, timeout: 30).choose(p)
        print("live OpenAI \(model) picked \(picks)")
        #expect(Set(picks).isSubset(of: Set(p.refs)))
    }
}
