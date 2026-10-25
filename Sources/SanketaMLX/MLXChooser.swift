import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration
import Tokenizers
import SanketaCore
import SanketaAI

/// Reads the tokenizer from the model folder with swift-transformers. It makes no network request.
public struct LocalTokenizerLoader: TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// A swift-transformers tokenizer as an MLXLMCommon tokenizer.
struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do { return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext) }
        catch Tokenizers.TokenizerError.missingChatTemplate { throw MLXLMCommon.TokenizerError.missingChatTemplate }
    }
}

/// What the chooser runs: the MLX model, or a fake in tests. It gives the model's raw answer text.
protocol PickRunner: Sendable {
    func run(_ prompt: ChoicePrompt, schema: String) async throws -> String
    /// A longer answer that the JSON `schema` limits, such as a pack for Make a Pack.
    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String
    /// Frees the model; called once, when the holder drops it.
    func release()
}

extension PickRunner {
    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String { throw ChoiceError.badResponse }
}

/// The files of a model folder must be plain data: regular files, none executable, no links.
enum ModelFolder {
    enum Problem: Error, Equatable { case notData(String) }

    static func check(_ dir: URL) throws {
        let fm = FileManager.default
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let a = try fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            let mode = (a[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard a[.type] as? FileAttributeType == .typeRegular, mode & 0o111 == 0 else { throw Problem.notData(name) }
        }
    }
}

/// The loaded MLX model with the grammar tokenizer and whitespace bias built once from its tokenizer.
final class MLXRunner: PickRunner, @unchecked Sendable {
    static let maxTokens = 64
    /// The prompts are at most about 2,000 tokens; a longer one gives `.contextExceeded`, so the router halves it.
    static let maxPromptTokens = 4096

    private let lock = NSLock()
    private var container: ModelContainer?
    let grammar: GrammarTokenizer
    let whitespace: Biases

    struct Biases: @unchecked Sendable { let bias: MLXArray; let tokenIDs: Set<Int> }

    init(container: ModelContainer, grammar: GrammarTokenizer, whitespace: Biases) {
        self.container = container; self.grammar = grammar; self.whitespace = whitespace
    }

    static func load(_ dir: URL) async throws -> MLXRunner {
        try ModelFolder.check(dir)
        guard MLXRuntime.prepare() else { throw ChoiceError.badResponse }
        let c = try await loadModelContainer(from: dir, using: LocalTokenizerLoader())
        let (g, ws) = try await c.perform { ctx in
            let v = TokenizerVocabExtractor.extractForGrammar(from: ctx.tokenizer)
            let g = try GrammarTokenizer(vocab: v.vocab, vocabType: v.vocabType, eosTokenId: Int32(ctx.tokenizer.eosTokenId ?? 0))
            let ws = WhitespaceTokenBias.compute(tokenizer: ctx.tokenizer)
            eval(ws.bias)
            return (g, Biases(bias: ws.bias, tokenIDs: ws.tokenIDs))
        }
        // the load leaves about as much again in MLX's buffer cache (5.3 GB for Gemma); free it, and keep it small
        Memory.cacheLimit = cacheLimit
        Memory.clearCache()
        return MLXRunner(container: c, grammar: g, whitespace: ws)
    }

    /// MLX's buffer cache while a model is loaded: enough for the prompt and KV buffers of one search.
    static let cacheLimit = 256 << 20

    func run(_ p: ChoicePrompt, schema: String) async throws -> String {
        try await generate(system: p.instructions, user: p.userText, schema: schema, maxTokens: Self.maxTokens)
    }

    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        guard let c = lock.withLock({ container }) else { throw ChoiceError.badResponse }
        let g = grammar, ws = whitespace
        return try await c.perform { ctx in
            let input = try await ctx.processor.prepare(input: UserInput(
                chat: [.system(system), .user(user)], additionalContext: ["enable_thinking": false]))
            if input.text.tokens.size > Self.maxPromptTokens { throw ChoiceError.contextExceeded }
            var out = ""
            do {
                let constraint = try GrammarConstraint(tokenizer: g, jsonSchema: schema, fastForward: true, hostTokenizer: ctx.tokenizer)
                try GuidedGenerationLoop.run(input: input, context: ctx, constraint: constraint, maxTokens: maxTokens,
                                             vocabSize: g.vocabSize, whitespaceBias: ws.bias, whitespaceTokenIDs: ws.tokenIDs) {
                    out += $0
                    return !Task.isCancelled
                }
            } catch is GuidedGenerationError { throw ChoiceError.badResponse }
            catch is GrammarError { throw ChoiceError.badResponse }
            try Task.checkCancellation()
            return out
        }
    }

    func release() {
        lock.withLock { container = nil }
        Memory.clearCache()
    }
}

/// One holder per model folder, so a new chooser after a config reload uses the model already loaded. It also keeps
/// one model in memory at most, and notes the folders whose model did not load in this process.
final class Holders: @unchecked Sendable {
    static let shared = Holders()
    private let lock = NSLock()
    private var all: [String: IdleHolder<any PickRunner>] = [:]
    private var failed: Set<String> = []

    func holder(_ key: String, make: () -> IdleHolder<any PickRunner>) -> IdleHolder<any PickRunner> {
        lock.withLock {
            if let h = all[key] { return h }
            let h = make()
            all[key] = h
            return h
        }
    }

    /// Unloads every model but the one for `key`; a model switch calls this before the new model loads.
    func dropOthers(_ key: String?) async {
        for (k, h) in lock.withLock({ all }) where k != key { await h.drop() }
    }

    func markFailed(_ key: String, _ yes: Bool) { lock.withLock { if yes { failed.insert(key) } else { failed.remove(key) } } }
    func didFail(_ key: String) -> Bool { lock.withLock { failed.contains(key) } }
    /// Forgets that the model for `key` (nil: every model) did not load, so the next search tries it again.
    func forgetFailure(_ key: String?) { lock.withLock { if let key { failed.remove(key) } else { failed = [] } } }
}

/// The downloaded MLX model as the on-device chooser. It loads in the background, runs off the main thread, answers
/// JSON that a grammar limits to the candidate refs, and frees its memory after `idle` seconds with no search. While
/// it loads, a search gets `.loading` at once, so the results stay plain, and the next search uses the model.
public struct MLXChooser: OnDeviceChooser {
    public let name: String
    let available: @Sendable () -> ModelStatus
    let holder: IdleHolder<any PickRunner>
    let key: String
    let registry: Holders

    public init(spec: ModelSpec, installer: ModelInstaller, idle: TimeInterval = 60) {
        let dir = installer.directory(spec)
        self.init(name: "on-device (\(spec.choice.displayName))", key: dir.path, idle: idle,
                  failedNote: Self.failedNote(spec.choice),
                  available: { Self.status(installed: installer.isInstalled(spec), ready: MLXRuntime.isReady) },
                  load: { try await MLXRunner.load(dir) })
    }

    init(name: String, key: String, registry: Holders = .shared, idle: TimeInterval, failedNote: String,
         available: @escaping @Sendable () -> ModelStatus, load: @escaping @Sendable () async throws -> any PickRunner) {
        self.name = name; self.key = key; self.registry = registry
        self.available = { registry.didFail(key) ? .unavailable(failedNote) : available() }
        holder = registry.holder(key) {
            IdleHolder(idle: idle, load: {
                await registry.dropOthers(key)
                do {
                    let r = try await load()
                    registry.markFailed(key, false)
                    return r
                } catch {
                    registry.markFailed(key, true)
                    throw error
                }
            }, unload: { $0.release() })
        }
    }

    /// Why the chooser is off after its model did not load. Gemma names the model to use in its place.
    public static func failedNote(_ c: MLXModelChoice) -> String {
        c == .gemma4e4b ? "\(c.displayName) did not load; choose \(MLXModelChoice.qwen4b6.displayName) in the On-Device Model menu"
            : "\(c.displayName) did not load"
    }

    /// True when the model in `dir` did not load in this process.
    public static func didFail(_ dir: URL) -> Bool { Holders.shared.didFail(dir.path) }

    /// After a download or a remove: a model in `dir` (nil: any) that did not load gets a new try.
    public static func forgetFailure(_ dir: URL?) { Holders.shared.forgetFailure(dir?.path) }

    /// Unloads every on-device model, such as before its files are removed.
    public static func unloadAll() async { await Holders.shared.dropOthers(nil) }

    /// `ready` is asked only for an installed model, so a status check does not look for the MLX shaders before then.
    static func status(installed: Bool, ready: @autoclosure () -> Bool) -> ModelStatus {
        if !installed { return .unavailable("on-device model not downloaded") }
        if !ready() { return .unavailable("on-device model needs the app build") }
        return .available
    }

    public func status() -> ModelStatus { available() }

    /// True while the model is in memory.
    public var isLoaded: Bool { get async { await holder.isLoaded } }

    /// `{"picks": [...]}` with each item one of `refs`, at most `maxPicks`.
    static func schema(refs: [String], maxPicks: Int) -> String {
        let obj: [String: Any] = [
            "type": "object",
            "properties": ["picks": ["type": "array", "items": ["enum": refs], "maxItems": maxPicks]],
            "required": ["picks"], "additionalProperties": false,
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)
    }

    /// The picks from the answer, which must be exactly `{"picks": [strings]}`; else `.badResponse`. Unknown refs stay:
    /// `Grounding` drops them.
    static func picks(from text: String) throws -> [String] {
        struct Answer: Decodable { let picks: [String] }
        guard let a = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8)),
              let keys = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], keys.count == 1
        else { throw ChoiceError.badResponse }
        return a.picks
    }

    public func choose(_ prompt: ChoicePrompt) async throws -> [String] {
        guard !prompt.refs.isEmpty else { return [] }
        // no wait for a load: this search stays plain, and the load goes on for the next one
        guard await holder.isLoaded else { startLoad(); throw ChoiceError.loading }
        let holder = holder, schema = Self.schema(refs: prompt.refs, maxPicks: prompt.maxPicks)
        // a detached task: the model never runs on the caller's actor, and a cancel reaches its token loop
        let work = Task.detached(priority: .userInitiated) { try await holder.use { try await $0.run(prompt, schema: schema) } }
        let text = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        return try Self.picks(from: text)
    }

    func startLoad() {
        let holder = holder
        Task.detached(priority: .utility) { _ = try? await holder.use { _ in true } }
    }

    /// Starts the load in the background, so the first search does not wait for it.
    public func prewarm() {
        guard status() == .available else { return }
        startLoad()
    }

    /// The answer tokens for Make a Pack: about 25 keys and 6 tips in JSON.
    public static let packTokens = 1500

    /// Make a Pack: the JSON answer (`PackMaker.jsonSchema`) to the variant B prompt. It waits for the model to load,
    /// runs off the caller's actor and stops when the caller is cancelled. The network is not used.
    public func makePack(_ prompt: String) async throws -> String {
        let holder = holder
        let work = Task.detached(priority: .userInitiated) {
            try await holder.use { try await $0.generate(system: "You write Sanketa shortcut packs. Output only JSON.", user: prompt,
                                                         schema: PackMaker.jsonSchema, maxTokens: Self.packTokens) }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Loads the model and waits for it; for the live test and `--ask`. Throws why it did not load.
    public func load() async throws { _ = try await holder.use { _ in true } }
}
