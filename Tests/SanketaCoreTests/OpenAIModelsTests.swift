import Testing
import Foundation
@testable import SanketaCore

private let items = [
    entry("tmux", "Split pane left/right", "prefix %"),
    entry("tmux", "Split pane top/bottom", "prefix \""),
    entry("vim", "Split window", ":vsplit"),
]

private func json(_ d: Data) throws -> [String: Any] { try #require(JSONSerialization.jsonObject(with: d) as? [String: Any]) }

@Suite struct OpenAIModelsTests {
    @Test func chatCapableFiltersOpenAIList() {
        let ids = ["gpt-5-nano", "gpt-5-nano-2025-08-07", "gpt-4o-mini-tts", "gpt-4o-audio-preview", "text-embedding-3-small",
                   "o4-mini", "dall-e-3", "gpt-4.1-mini", "whisper-1", "omni-moderation-latest"]
        #expect(OpenAIModels.chatCapable(ids, openAI: true) == ["gpt-4.1-mini", "gpt-5-nano", "o4-mini"])
        #expect(OpenAIModels.chatCapable(ids, openAI: false) == ids.sorted())
    }

    @Test func cheapestFollowsPreference() {
        #expect(OpenAIModels.cheapest(["gpt-4.1-mini", "gpt-5-mini", "gpt-4o-mini"]) == "gpt-4o-mini")
        #expect(OpenAIModels.cheapest(["gpt-9-nano", "gpt-8-nano", "gpt-9-mini"]) == "gpt-8-nano")
        #expect(OpenAIModels.cheapest(["zeta-mini", "alpha-mini"]) == "alpha-mini")
        #expect(OpenAIModels.cheapest(["llama3.2", "qwen3:4b"]) == "llama3.2")
        #expect(OpenAIModels.cheapest([]) == nil)
    }

    @Test func hostRules() throws {
        #expect(OpenAIModels.isOpenAI(try #require(URL(string: "https://api.openai.com/v1"))))
        #expect(!OpenAIModels.isOpenAI(try #require(URL(string: "https://openrouter.ai/api/v1"))))
        for s in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1"] {
            #expect(OpenAIModels.isLocal(try #require(URL(string: s))))
        }
        #expect(!OpenAIModels.isLocal(try #require(URL(string: "https://api.openai.com/v1"))))
        #expect(OpenAIModels.isReasoning("o4-mini") && OpenAIModels.isReasoning("gpt-5-nano"))
        #expect(!OpenAIModels.isReasoning("gpt-4o-mini") && !OpenAIModels.isReasoning("gpt-4.1-nano"))
    }

    @Test func bodyIsExactlyWhatLeaves() async throws {
        let (prompt, _) = ChoicePrompt.build(task: .search("split the pane side by side"), candidates: items, maxPicks: 5)
        #expect(prompt.refs.count == 3)

        let b = try json(OpenAIRequest.body(model: "gpt-4o-mini", prompt: prompt, openAI: true))
        #expect(Set(b.keys) == ["model", "messages", "response_format", "store", "max_completion_tokens"])
        #expect(b["model"] as? String == "gpt-4o-mini")
        #expect(b["store"] as? Bool == false)
        #expect(b["max_completion_tokens"] as? Int == 100)
        let msgs = try #require(b["messages"] as? [[String: String]])
        #expect(msgs == [["role": "system", "content": prompt.instructions], ["role": "user", "content": prompt.userText]])
        let rf = try #require(b["response_format"] as? [String: Any])
        #expect(rf["type"] as? String == "json_schema")
        let js = try #require(rf["json_schema"] as? [String: Any])
        #expect(js["name"] as? String == "choice" && js["strict"] as? Bool == true)
        let schema = try #require(js["schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["picks"])
        #expect(schema["additionalProperties"] as? Bool == false)
        let picks = try #require((schema["properties"] as? [String: Any])?["picks"] as? [String: Any])
        #expect(picks["type"] as? String == "array" && picks["maxItems"] as? Int == 5)
        let itemsSchema = try #require(picks["items"] as? [String: Any])
        #expect(itemsSchema["type"] as? String == "string")
        #expect(itemsSchema["enum"] as? [String] == prompt.refs)

        let r = try json(OpenAIRequest.body(model: "gpt-5-nano", prompt: prompt, openAI: true))
        #expect(Set(r.keys) == ["model", "messages", "response_format", "store", "max_completion_tokens", "reasoning_effort"])
        #expect(r["reasoning_effort"] as? String == "low")
        #expect(r["max_completion_tokens"] as? Int == 1000)

        let o = try json(OpenAIRequest.body(model: "llama3.2", prompt: prompt, openAI: false))
        #expect(Set(o.keys) == ["model", "messages", "response_format", "max_tokens"])
        #expect(o["max_tokens"] as? Int == 100)

        let plain = try json(OpenAIRequest.body(model: "llama3.2", prompt: prompt, openAI: false, schema: false))
        #expect(Set(plain.keys) == ["model", "messages", "max_tokens"])

        // history never reaches the remote prompt, so it never reaches the body
        let history = ["git push --force origin secret-branch", "export TOKEN=hunter2", "tmux split-window -h"]
            .map { HistoryEntry(command: $0, shell: .fish) }
        var cfg = LLMConfig(); cfg.onDevice = false; cfg.appleFM = false; cfg.openai = true
        let remote = RecordingChooser(isRemote: true)
        _ = await SmartSearch(router: ModelRouter(config: cfg, onDevice: nil, appleFM: nil, remote: remote), timeout: 60)
            .results("split the pane side by side", items, context: ["tmux"])
        let sent = await remote.prompts
        #expect(sent.count == 1)
        for p in sent {
            let body = String(decoding: OpenAIRequest.body(model: "gpt-4o-mini", prompt: p, openAI: true), as: UTF8.self)
            for h in history {
                #expect(!p.lines.contains { $0.contains(h.command) })
                #expect(!p.userText.contains(h.command) && !body.contains(h.command))
            }
        }
    }

    @Test func parseReadsPicks() throws {
        let d = Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"picks\":[\"e2\",\"e5\"]}"}}]}"#.utf8)
        #expect(try OpenAIRequest.parse(d) == ["e2", "e5"])
    }

    @Test func parseRejectsGarbage() {
        for s in [#"{"choices":[]}"#, "oops", #"{"choices":[{"message":{"content":"not json"}}]}"#] {
            #expect(throws: ChoiceError.badResponse) { try OpenAIRequest.parse(Data(s.utf8)) }
        }
    }
}
