import Foundation

public enum ModelStatus: Equatable, Sendable { case available, unavailable(String), off }

/// `loading`: the model is still loading in the background, so this search is plain and a later one uses it.
/// `busy`: the on-device model is writing a pack (Make a Pack), so this search is plain and does not wait.
public enum ChoiceError: Error, Equatable { case contextExceeded, notAllowed, http(Int), badResponse, noKey, loading, busy }

/// A model that picks refs from a `ChoicePrompt`. It never sees anything but the prompt.
public protocol Choosing: Sendable {
    var name: String { get }
    var isRemote: Bool { get }
    func status() -> ModelStatus
    func choose(_ prompt: ChoicePrompt) async throws -> [String]
    func prewarm()
}

public extension Choosing { func prewarm() {} }

/// The slot for the downloaded on-device model, tried first.
public protocol OnDeviceChooser: Choosing {}

public extension OnDeviceChooser { var isRemote: Bool { false } }

/// Picks a chooser in the order on-device model, Apple Foundation Models, OpenAI-compatible server.
public struct ModelRouter: Sendable {
    public var config: LLMConfig
    public var onDevice: (any OnDeviceChooser)?
    public var appleFM: (any Choosing)?
    public var remote: (any Choosing)?

    public init(config: LLMConfig, onDevice: (any OnDeviceChooser)?, appleFM: (any Choosing)?, remote: (any Choosing)?) {
        self.config = config; self.onDevice = onDevice; self.appleFM = appleFM; self.remote = remote
    }

    /// Enabled tiers in order, with the reason to give when the tier has no chooser.
    func tiers(remote withRemote: Bool) -> [(chooser: (any Choosing)?, missing: String)] {
        var t: [(chooser: (any Choosing)?, missing: String)] = []
        if config.onDevice { t.append((onDevice, "on-device model is not set up")) }
        if config.appleFM { t.append((appleFM, "Apple Intelligence is not available")) }
        if withRemote && config.openai { t.append((remote, "OpenAI server is not set up")) }
        return t
    }

    static func first(_ tiers: [(chooser: (any Choosing)?, missing: String)]) -> (any Choosing)? {
        tiers.lazy.compactMap(\.chooser).first { $0.status() == .available }
    }

    public func searchChooser() -> (any Choosing)? { Self.first(tiers(remote: true)) }

    /// On-device tiers only: the suggestion prompt holds shell history, which never leaves the machine.
    public func suggestChooser() -> (any Choosing)? {
        guard config.suggest else { return nil }
        return Self.first(tiers(remote: false)).flatMap { $0.isRemote ? nil : $0 }
    }

    public func searchNote() -> String? {
        if searchChooser() != nil { return nil }
        let reasons = tiers(remote: true).compactMap { t -> String? in
            guard let c = t.chooser else { return t.missing }
            if case .unavailable(let why) = c.status() { return why }
            return nil
        }
        return "Plain search: " + (reasons.isEmpty ? "no model turned on" : reasons.joined(separator: "; "))
    }

    public func prewarm() { searchChooser()?.prewarm() }
}

struct TimedOut: Error {}

/// Resumes a continuation once; a result that comes before the continuation is kept for it.
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    private var early: Result<T, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<T, Error>) {
        let r: Result<T, Error>? = lock.withLock { if let e = early { early = nil; return e }; cont = c; return nil }
        if let r { c.resume(with: r) }
    }

    func resume(_ r: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            if done { return nil }
            done = true
            if let c = cont { cont = nil; return c }
            early = r; return nil
        }
        c?.resume(with: r)
    }
}

private let deadlineQueue = DispatchQueue(label: "dev.sanketa.model-deadline")

/// Calls the chooser with a deadline that the router owns: at the timeout, or when the caller is cancelled, it
/// cancels the call and returns at once, even when the chooser does not stop. A late answer is dropped.
/// On `.contextExceeded` it tries once more with half the entries, inside the same deadline.
func choosePicks(_ chooser: any Choosing, _ prompt: ChoicePrompt, timeout: TimeInterval) async throws -> (picks: [String], prompt: ChoicePrompt) {
    typealias Answer = (picks: [String], prompt: ChoicePrompt)
    let once = OneShot<Answer>()
    let work = Task<Answer, Error> {
        do { return (try await chooser.choose(prompt), prompt) }
        catch ChoiceError.contextExceeded {
            let h = prompt.halved()
            return (try await chooser.choose(h), h)
        }
    }
    Task { once.resume(await work.result) }
    // the deadline fires from its own queue, so a busy Swift thread pool cannot delay it
    let deadline = DispatchWorkItem {
        once.resume(.failure(TimedOut()))
        work.cancel()
    }
    deadlineQueue.asyncAfter(deadline: .now() + timeout, execute: deadline)
    defer { deadline.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { once.set($0) }
    } onCancel: {
        once.resume(.failure(CancellationError()))
        work.cancel()
    }
}

public struct SmartResult: Equatable, Sendable {
    public var items: [SearchItem]
    /// ids of the items the model chose; they come first
    public var picked: Set<String>
    public var note: String?

    public init(items: [SearchItem], picked: Set<String> = [], note: String? = nil) {
        self.items = items; self.picked = picked; self.note = note
    }
}

/// Plain search, with the model's picks moved to the top for requests of 3 or more words.
public struct SmartSearch: Sendable {
    public var router: ModelRouter
    public var timeout: TimeInterval
    public static let maxPicks = 5

    public init(router: ModelRouter, timeout: TimeInterval) { self.router = router; self.timeout = timeout }

    static func reason(_ e: Error) -> String {
        switch e {
        case is TimedOut: return "timed out"
        case ChoiceError.notAllowed: return "refused the request"
        case ChoiceError.noKey: return "no key"
        case ChoiceError.loading: return "is loading"
        case ChoiceError.busy: return "is busy writing a pack"
        case ChoiceError.http(let n): return "HTTP \(n)"
        default: return "failed"
        }
    }

    public func results(_ query: String, _ items: [SearchItem], context: [String]) async -> SmartResult {
        let ranked = Search.rank(query, items, context: context)
        var seen = Set<String>()
        let local = (ranked.isEmpty ? Retrieval.candidates(query, items, context: context) : ranked).filter { seen.insert($0.id).inserted }
        guard query.split(whereSeparator: \.isWhitespace).count >= 3 else { return SmartResult(items: local) }
        guard let chooser = router.searchChooser() else { return SmartResult(items: local, note: router.searchNote()) }
        // allow-list: only entries marked by `SearchItem.items(from:)` for TOML packs and live tmux keys
        let pool = chooser.isRemote ? items.filter(\.mayLeave) : items
        let cands = Retrieval.candidates(query, pool, context: context)
        guard !cands.isEmpty else { return SmartResult(items: local) }
        let (prompt, refs) = ChoicePrompt.build(task: .search(query), candidates: cands, maxPicks: Self.maxPicks)
        do {
            let (picks, used) = try await choosePicks(chooser, prompt, timeout: timeout)
            let chosen = Grounding.resolve(picks, refs.filter { used.refs.contains($0.key) }, order: used.refs, max: Self.maxPicks)
            let ids = Set(chosen.map(\.id))
            return SmartResult(items: chosen + local.filter { !ids.contains($0.id) }, picked: ids)
        } catch {
            return SmartResult(items: local, note: "Plain search: \(chooser.name) \(Self.reason(error))")
        }
    }
}

/// Up to 2 pack entries chosen by an on-device model for what the recent commands do.
public enum SmartSuggest {
    static let wrappers: Set<String> = ["sudo", "env", "command"]
    public static let maxPicks = 2

    /// The command names of each stage of `command`, past `sudo`, `env`, `command`, their options and `X=Y` words.
    static func names(_ command: String, shell: Shell) -> [String] {
        ShellLex.commands(command, shell: shell).flatMap(\.stages).compactMap { stage in
            let w = stage.map(\.value).drop { wrappers.contains($0) || $0.hasPrefix("-")
                || $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil }
            return w.first.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public static func candidates(recent: [HistoryEntry], library: PackLibrary, items: [SearchItem], excluding: Set<String>,
                                  limit: Int = 30) -> [SearchItem] {
        var packs: [String] = []
        for e in recent.suffix(ChoicePrompt.commandCount).reversed() {
            for n in names(e.command, shell: e.shell) {
                if let p = library.pack(process: n, argv: [n]), !packs.contains(p.id) { packs.append(p.id) }
            }
        }
        let byPack = Dictionary(grouping: items.filter { $0.kind == .tip || $0.kind == .key }, by: \.packID)
        return Array(packs.flatMap { byPack[$0] ?? [] }.filter { !excluding.contains($0.id) }.prefix(limit))
    }

    public static func pick(recent: [HistoryEntry], library: PackLibrary, items: [SearchItem], excluding: Set<String>,
                            router: ModelRouter, timeout: TimeInterval) async -> [SearchItem] {
        guard let chooser = router.suggestChooser(), !chooser.isRemote else { return [] }
        let cands = candidates(recent: recent, library: library, items: items, excluding: excluding)
        guard !cands.isEmpty else { return [] }
        let cmds = recent.suffix(ChoicePrompt.commandCount).map(\.command)
        let (prompt, refs) = ChoicePrompt.build(task: .suggest(cmds), candidates: cands, maxPicks: maxPicks)
        guard let (picks, used) = try? await choosePicks(chooser, prompt, timeout: timeout) else { return [] }
        return Grounding.resolve(picks, refs.filter { used.refs.contains($0.key) }, order: used.refs, max: maxPicks)
    }
}

/// Where the API key came from. Copy Debug Info shows only this, never the key.
public enum KeySource: String, Sendable { case environment, shell, keychain = "Keychain" }

/// Lets a call through at most once per `interval` seconds, such as the model prewarm when the panel opens.
public final class Throttle: @unchecked Sendable {
    let interval: TimeInterval
    private let lock = NSLock()
    private var last: Date?

    public init(_ interval: TimeInterval) { self.interval = interval }

    /// True, and the clock restarts, when `interval` has passed since the last true.
    public func ready(now: Date = Date()) -> Bool {
        lock.withLock {
            if let l = last, now.timeIntervalSince(l) < interval { return false }
            last = now
            return true
        }
    }
}
