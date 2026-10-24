import Foundation
import SanketaCore

/// The server's chat model list, kept for `ttl` seconds, so a search never waits for `GET /models`. A failed fetch is
/// kept for `failureTTL` seconds, so a bad key does not give one request per search. Calls that come while a fetch
/// runs wait for the same answer.
public actor ModelListCache {
    let fetch: @Sendable () async throws -> [String]
    let now: @Sendable () -> Date
    let ttl: TimeInterval, failureTTL: TimeInterval
    private var list: [String]?
    private var fetchedAt: Date?
    private var failure: (error: Error, at: Date)?
    private var running: Task<[String], Error>?

    public init(ttl: TimeInterval = 600, failureTTL: TimeInterval = 60, now: @escaping @Sendable () -> Date = Date.init,
                fetch: @escaping @Sendable () async throws -> [String]) {
        self.ttl = ttl; self.failureTTL = failureTTL; self.now = now; self.fetch = fetch
    }

    /// The last list that loaded, for the menu to show at once.
    public var cached: [String]? { list }

    /// The kept list while it is fresh, else a new fetch.
    public func models() async throws -> [String] {
        if let list, let t = fetchedAt, now().timeIntervalSince(t) < ttl { return list }
        if running == nil, let f = failure, now().timeIntervalSince(f.at) < failureTTL { throw f.error }
        return try await refresh()
    }

    /// Fetches now (the model menu opened), or waits for the fetch that runs.
    public func refresh() async throws -> [String] {
        let task = running ?? Task { try await fetch() }
        running = task
        do {
            let l = try await task.value
            if running == task { running = nil; list = l; fetchedAt = now(); failure = nil }
            return l
        } catch {
            if running == task { running = nil; failure = (error, now()) }
            throw error
        }
    }

    /// Forgets a failed fetch, so the next call asks again (a new key was saved).
    public func reset() { failure = nil }

    /// The cheapest chat model in the list; nil when the list does not load.
    public func cheapest() async -> String? { OpenAIModels.cheapest((try? await models()) ?? []) }
}

/// The model tiers from `[llm]`. The key lookup and the model-list cache live as long as `base_url` and `api_key_env`
/// stay the same, so the login shell is asked once and the list is fetched once per 10 minutes.
public struct LLMSetup: Sendable {
    public let config: LLMConfig
    /// nil when `base_url` is not a URL
    public let baseURL: URL?
    public let keys: KeyLookup?
    public let models: ModelListCache?
    public let router: ModelRouter

    /// `makeKeys` gets the Keychain account (the server's host) and is called only when `previous` can't be reused.
    public init(config: LLMConfig, previous: LLMSetup? = nil, makeKeys: (_ account: String) -> KeyLookup,
                session: URLSession = .shared, onDevice: (any OnDeviceChooser)?, appleFM: (any Choosing)?) {
        self.config = config
        let url = URL(string: config.baseURL).flatMap { $0.host == nil ? nil : $0 }
        baseURL = url
        if let previous, previous.config.baseURL == config.baseURL, previous.config.apiKeyEnv == config.apiKeyEnv {
            keys = previous.keys; models = previous.models
        } else if let url {
            let k = makeKeys(APIKey.account(for: url))
            keys = k
            models = ModelListCache {
                // no request without a key, except to a server on this Mac
                let key = await k.key()
                if (key ?? "").isEmpty && !OpenAIModels.isLocal(url) { throw ChoiceError.noKey }
                return try await ModelList.fetch(baseURL: url, key: key, session: session)
            }
        } else {
            keys = nil; models = nil
        }
        var remote: (any Choosing)?
        if config.openai, let url, let keys, let models {
            let pinned = config.openaiModel
            remote = OpenAIChooser(baseURL: url, model: { pinned.isEmpty ? await models.cheapest() : pinned },
                                   key: { await keys.key() }, session: session, timeout: config.timeoutSeconds)
        }
        router = ModelRouter(config: config, onDevice: onDevice, appleFM: appleFM, remote: remote)
    }

    /// "OpenAI" for api.openai.com, else the server's host, for menu titles.
    public var providerName: String {
        guard let baseURL else { return "OpenAI" }
        return OpenAIModels.isOpenAI(baseURL) ? "OpenAI" : OpenAIModels.host(baseURL)
    }
}
