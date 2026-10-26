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
        let unusable = ["gpt-5-chat-latest", "gpt-5-pro", "o3-pro", "o1-pro-2025-03-19", "o1-mini", "o1-preview", "gpt-5-codex"]
        #expect(OpenAIModels.chatCapable(unusable + ["gpt-5-mini", "o3", "o1"], openAI: true) == ["gpt-5-mini", "o1", "o3"])
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
        for s in ["https://api.openai.com/v1", "https://openrouter.ai/api/v1", "http://localhost:11434/v1", "http://[::1]:8080/v1"] {
            #expect(OpenAIModels.isAllowed(try #require(URL(string: s))))
        }
        for s in ["HTTPS://api.openai.com/v1", "HTTP://LOCALHOST:11434/v1", "Http://127.0.0.1:1234/v1"] {
            #expect(OpenAIModels.isAllowed(try #require(URL(string: s))), "\(s)")
        }
        #expect(OpenAIModels.isOpenAI(try #require(URL(string: "HTTPS://API.OPENAI.COM/v1"))))
        #expect(!OpenAIModels.isOpenAI(try #require(URL(string: "https://api.openai.com@evil.com/v1"))))
        for s in ["http://api.openai.com/v1", "http://192.168.1.20:11434/v1", "ftp://localhost/v1", "http://localhost.evil.com/v1",
                  "HTTP://api.openai.com/v1", "http://localhost@evil.com/v1", "http://localhost:pw@evil.com:11434/v1",
                  "http://[::ffff:127.0.0.1]:1234/v1", "http://127.0.0.2/v1", "http://0.0.0.0:11434/v1"] {
            #expect(!OpenAIModels.isAllowed(try #require(URL(string: s))), "\(s)")
        }
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

    }

    @Test func remotePoolHoldsOnlyPackEntries() async {
        let coach = Coach.analyze([HistoryEntry(command: "cat deploy-secrets.log | grep 404 | wc -l", shell: .fish)]).map(\.item)
        #expect(!coach.isEmpty)
        let menu = SearchItem(packID: "app:com.apple.TextEdit", packName: "TextEdit Menus", kind: .key,
                              title: "Close Split budget.docx", detail: "⌘W")
        // a source added later that nobody marked: it stays on this Mac by default
        let unknown = SearchItem(packID: "zz-new-source", packName: "New source", kind: .tip, title: "Count matches in Q4 forecast",
                                 detail: "private-note")
        let all = items + coach + [menu, unknown]
        var cfg = LLMConfig(); cfg.onDevice = false; cfg.appleFM = false; cfg.openai = true
        let remote = RecordingChooser(isRemote: true)
        let query = "count matches then split the pane"
        _ = await SmartSearch(router: ModelRouter(config: cfg, onDevice: nil, appleFM: nil, remote: remote), timeout: 60)
            .results(query, all, context: ["tmux"])
        // the same query does reach the coaching and menu entries when the model is on this Mac
        cfg.appleFM = true
        let local = RecordingChooser()
        _ = await SmartSearch(router: ModelRouter(config: cfg, onDevice: nil, appleFM: local, remote: nil), timeout: 60)
            .results(query, all, context: ["tmux"])
        let localText = await local.prompts.map(\.userText).joined()
        #expect(localText.contains("deploy-secrets") && localText.contains("budget.docx") && localText.contains("Q4 forecast"))
        let sent = await remote.prompts
        #expect(sent.count == 1)
        let text = sent.map(\.userText).joined()
        #expect(!text.contains("deploy-secrets") && !text.contains("Better ways") && !text.contains("budget.docx"))
        #expect(!text.contains("Q4 forecast") && !text.contains("private-note"))
        #expect(text.contains("Split pane left/right"))
        #expect(all.filter(\.mayLeave) == items)
    }

    @Test func onlyTOMLAndLiveTmuxEntriesMayLeave() throws {
        let toml = try PackLibrary.decode(Data("""
            id = "tmux"
            name = "tmux"
            [[keys]]
            keys = "prefix %"
            action = "Split pane left/right"
            command = "split-window -h"
            [[tips]]
            title = "Zoom a pane"
            snippet = "prefix z"
            """.utf8))
        #expect(SearchItem.items(from: toml).count == 2 && SearchItem.items(from: toml).allSatisfy(\.mayLeave))
        let live = Tmux.mergeLive(toml, live: [KeyEntry(keys: "prefix |", action: "split-window -h", command: "split-window -h"),
                                                KeyEntry(keys: "prefix R", action: "source-file ~/.tmux.conf")])
        #expect(SearchItem.items(from: live).count == 3 && SearchItem.items(from: live).allSatisfy(\.mayLeave))
        let menu = MenuKeys.pack(bundleID: "com.apple.TextEdit", name: "TextEdit",
                                 shortcuts: [MenuShortcut(path: ["File", "Close budget.docx"], keys: "⌘W", enabled: true)])
        #expect(!SearchItem.items(from: menu).isEmpty && SearchItem.items(from: menu).filter(\.mayLeave).isEmpty)
        #expect(SearchItem.items(from: Pack(id: "made-in-code", name: "x", keys: [KeyEntry(keys: "a", action: "b")])).filter(\.mayLeave).isEmpty)
    }

    @Test func parseReadsPicks() throws {
        let d = Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"picks\":[\"e2\",\"e5\"]}"}}]}"#.utf8)
        #expect(try OpenAIRequest.parse(d) == ["e2", "e5"])
    }

    @Test func parseStripsFencesAndThinking() throws {
        func reply(_ content: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
        }
        for c in ["```json\n{\"picks\":[\"e3\"]}\n```", "```\n{\"picks\":[\"e3\"]}```",
                  "<think>\nThe user wants e1? No, e3.\n</think>\n\n{\"picks\":[\"e3\"]}",
                  "<think>hmm</think>```json\n{\"picks\": [\"e3\"]}\n```"] {
            #expect(try OpenAIRequest.parse(reply(c)) == ["e3"])
        }
    }

    @Test func parseRejectsGarbage() {
        for s in [#"{"choices":[]}"#, "oops", #"{"choices":[{"message":{"content":"not json"}}]}"#] {
            #expect(throws: ChoiceError.badResponse) { try OpenAIRequest.parse(Data(s.utf8)) }
        }
    }

    @Test func displayNamesArePlain() {
        let want = ["gpt-5-nano": "GPT-5 Nano", "gpt-4.1-mini": "GPT-4.1 Mini", "gpt-4o-mini": "GPT-4o Mini", "gpt-4.1": "GPT-4.1",
                    "o3-mini": "o3 Mini", "o4": "o4", "chatgpt-4o-latest": "ChatGPT-4o Latest", "gpt-4o-2024-08-06": "GPT-4o 2024-08-06",
                    "llama3.2:3b": "llama3.2:3b", "anthropic/claude-x": "anthropic/claude-x", "gpt-image": "gpt-image"]
        for (id, name) in want { #expect(OpenAIModels.displayName(id) == name, "\(id)") }
    }
}
