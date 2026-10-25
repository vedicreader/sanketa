import Foundation
import SanketaCore

/// The request with the bearer key when there is one; the key goes only in the header.
func authorized(_ url: URL, key: String?, timeout: TimeInterval) -> URLRequest {
    var r = URLRequest(url: url, timeoutInterval: timeout)
    if let key, !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
    return r
}

/// Refuses every redirect, so the bearer key and the query can't be sent on to another host or over plain http.
/// The 3xx answer then shows as `.http(3xx)`.
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirect()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The status code; a non-2xx answer throws `.http`.
func checked(_ resp: URLResponse) throws -> Int {
    guard let h = resp as? HTTPURLResponse else { throw ChoiceError.badResponse }
    guard (200..<300).contains(h.statusCode) else { throw ChoiceError.http(h.statusCode) }
    return h.statusCode
}

/// An OpenAI-compatible chat completions server as a chooser. It sends only the search prompt: the request and
/// the candidate entries. Suggestion prompts hold shell history, so they are refused before any request.
public struct OpenAIChooser: Choosing {
    public let baseURL: URL
    public let isRemote = true
    let model: @Sendable () async -> String?
    let key: @Sendable () async -> String?
    let session: URLSession
    let timeout: TimeInterval

    /// `model` and `key` are asked for at each call, not at init.
    public init(baseURL: URL, model: @escaping @Sendable () async -> String?, key: @escaping @Sendable () async -> String?,
                session: URLSession = .shared, timeout: TimeInterval) {
        self.baseURL = baseURL; self.model = model; self.key = key; self.session = session; self.timeout = timeout
    }

    var openAI: Bool { OpenAIModels.isOpenAI(baseURL) }

    public var name: String { openAI ? "OpenAI" : (baseURL.host ?? baseURL.absoluteString) }

    /// Key and model problems show as errors from `choose`, so this never blocks. A plain http address to another
    /// machine is refused.
    public func status() -> ModelStatus { OpenAIModels.isAllowed(baseURL) ? .available : .unavailable(OpenAIModels.insecureNote) }

    public func choose(_ prompt: ChoicePrompt) async throws -> [String] {
        if case .suggest = prompt.task { throw ChoiceError.notAllowed }
        guard OpenAIModels.isAllowed(baseURL) else { throw ChoiceError.notAllowed }
        let key = await key()
        if (key ?? "").isEmpty && !OpenAIModels.isLocal(baseURL) { throw ChoiceError.noKey }
        guard let model = await model(), !model.isEmpty else { throw ChoiceError.badResponse }
        do {
            return try await post(model: model, prompt: prompt, key: key, schema: true)
        } catch ChoiceError.http(400) where !openAI {
            // some servers do not take `response_format`; Grounding still checks the picks
            return try await post(model: model, prompt: prompt, key: key, schema: false)
        }
    }

    func post(model: String, prompt: ChoicePrompt, key: String?, schema: Bool) async throws -> [String] {
        try Task.checkCancellation()
        var r = authorized(baseURL.appendingPathComponent("chat/completions"), key: key, timeout: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = OpenAIRequest.body(model: model, prompt: prompt, openAI: openAI, schema: schema)
        let (data, resp) = try await session.data(for: r, delegate: NoRedirect.shared)
        _ = try checked(resp)
        return try OpenAIRequest.parse(data)
    }
}

/// The chat models a server offers, for the model menu and the cheapest-model default.
public enum ModelList {
    public static func fetch(baseURL: URL, key: String?, session: URLSession = .shared, timeout: TimeInterval = 8) async throws -> [String] {
        struct Reply: Decodable { struct Model: Decodable { var id: String }; var data: [Model] }
        guard OpenAIModels.isAllowed(baseURL) else { throw ChoiceError.notAllowed }
        let req = authorized(baseURL.appendingPathComponent("models"), key: key, timeout: timeout)
        let (data, resp) = try await session.data(for: req, delegate: NoRedirect.shared)
        _ = try checked(resp)
        guard let r = try? JSONDecoder().decode(Reply.self, from: data) else { throw ChoiceError.badResponse }
        return OpenAIModels.chatCapable(r.data.map(\.id), openAI: OpenAIModels.isOpenAI(baseURL))
    }
}

/// "Send to OpenAI" for Make a Pack: one request with the prompt that the user saw and the model id. It has the same
/// guards as the chooser: https only (plain http only to this Mac), the key only in the header of a request to
/// `baseURL`, and no redirects. The prompt and the answer are not logged.
public struct PackMakerSender: Sendable {
    /// The model reads web pages, so the request can take minutes; the search timeout is too short.
    public static let timeout: TimeInterval = 180

    public let baseURL: URL
    let model: @Sendable () async -> String?
    let key: @Sendable () async -> String?
    let session: URLSession
    let timeout: TimeInterval

    public init(baseURL: URL, model: @escaping @Sendable () async -> String?, key: @escaping @Sendable () async -> String?,
                session: URLSession = .shared, timeout: TimeInterval = PackMakerSender.timeout) {
        self.baseURL = baseURL; self.model = model; self.key = key; self.session = session; self.timeout = timeout
    }

    public var name: String { OpenAIModels.isOpenAI(baseURL) ? "OpenAI" : OpenAIModels.host(baseURL) }

    /// The answer text of the model.
    public func send(_ prompt: String) async throws -> String {
        guard OpenAIModels.isAllowed(baseURL) else { throw ChoiceError.notAllowed }
        let key = await key()
        if (key ?? "").isEmpty && !OpenAIModels.isLocal(baseURL) { throw ChoiceError.noKey }
        guard let model = await model(), !model.isEmpty else { throw ChoiceError.badResponse }
        try Task.checkCancellation()
        let openAI = OpenAIModels.isOpenAI(baseURL)
        var r = authorized(baseURL.appendingPathComponent(PackMakerRequest.path(openAI: openAI)), key: key, timeout: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = PackMakerRequest.body(model: model, prompt: prompt, openAI: openAI)
        let (data, resp) = try await session.data(for: r, delegate: NoRedirect.shared)
        _ = try checked(resp)
        return try PackMakerRequest.parse(data, openAI: openAI)
    }
}
