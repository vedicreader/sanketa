import Testing
import Foundation
@testable import SanketaAI
import SanketaCore

private let openAI = URL(string: "https://api.openai.com/v1")!
private let toml = "id = \"rawtherapee\"\nname = \"RawTherapee\""
private let reply = """
{"output":[{"type":"web_search_call","status":"completed"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":\(String(decoding: try! JSONSerialization.data(withJSONObject: [toml], options: [.fragmentsAllowed]), as: UTF8.self).dropFirst().dropLast())}]}]}
"""
private let prompt = PackMaker.promptA(app: .init(name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee", version: "5.13"),
                                       menu: [MenuShortcut(path: ["RawTherapee", "Quit RawTherapee"], keys: "⌘Q")], existing: nil, urls: [])

private func sender(_ stub: Stub, base: URL = openAI, key: String? = "sk-test") -> PackMakerSender {
    PackMakerSender(baseURL: base, model: { "gpt-5-mini" }, key: { key }, session: stub.session)
}

@Suite struct PackMakerSenderTests {
    @Test func openAIGetsTheResponsesRequestWithWebSearch() async throws {
        let stub = Stub(["/v1/responses": [(200, reply)]])
        #expect(try await sender(stub).send(prompt) == toml)
        let r = try #require(stub.requests.first)
        #expect(stub.requests.count == 1)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/responses" && r.method == "POST")
        #expect(r.header("Authorization") == "Bearer sk-test" && r.timeout == 180)
        #expect(r.body == PackMakerRequest.body(model: "gpt-5-mini", prompt: prompt, openAI: true))
        // only the prompt and the model id: no title, path or user name in the body
        let body = String(decoding: r.body, as: UTF8.self)
        #expect(!body.contains(NSUserName()) && !body.contains(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    @Test func otherServerGetsAChatRequestWithNoTools() async throws {
        let base = URL(string: "https://llm.example/v1")!
        let stub = Stub(["/v1/chat/completions": [(200, #"{"choices":[{"message":{"content":"id = \"x\""}}]}"#)]])
        #expect(try await sender(stub, base: base).send(prompt) == "id = \"x\"")
        let r = try #require(stub.requests.first)
        #expect(r.json?["tools"] == nil && r.json?["messages"] != nil)
    }

    @Test func noKeyAndPlainHTTPSendNothing() async {
        let stub = Stub(["/v1/responses": [(200, reply)]])
        await #expect(throws: ChoiceError.noKey) { try await sender(stub, key: String?.none).send(prompt) }
        await #expect(throws: ChoiceError.notAllowed) { try await sender(stub, base: URL(string: "http://llm.example/v1")!).send(prompt) }
        #expect(stub.requests.isEmpty)
    }

    @Test func redirectIsNotFollowed() async {
        let stub = Stub(["/v1/responses": [(307, "https://evil.example/v1/responses")]])
        await #expect(throws: ChoiceError.http(307)) { try await sender(stub).send(prompt) }
        #expect(stub.requests.map { $0.url?.host } == ["api.openai.com"])
    }

    @Test func serverErrorAndBadAnswer() async {
        let stub = Stub(["/v1/responses": [(500, "{}"), (200, #"{"output":[]}"#)]])
        await #expect(throws: ChoiceError.http(500)) { try await sender(stub).send(prompt) }
        await #expect(throws: ChoiceError.badResponse) { try await sender(stub).send(prompt) }
    }
}
