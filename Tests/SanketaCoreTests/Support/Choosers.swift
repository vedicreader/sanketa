import Foundation
@testable import SanketaCore

/// Always returns the same picks.
struct FixedChooser: Choosing {
    var picks: [String]
    var state: ModelStatus = .available
    var isRemote = false
    var name = "fixed"
    init(picks: [String], status: ModelStatus = .available, isRemote: Bool = false) {
        self.picks = picks; self.state = status; self.isRemote = isRemote
    }
    func status() -> ModelStatus { state }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] { picks }
}

/// Always throws `error`.
struct ThrowingChooser: Choosing {
    var error: ChoiceError
    var name = "throwing"
    var isRemote: Bool { false }
    init(error: ChoiceError) { self.error = error }
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] { throw error }
}

/// Sleeps (cancellably) before it answers; `finished` turns true only when it answers.
final class SlowChooser: Choosing, @unchecked Sendable {
    let seconds: Double
    private let lock = NSLock()
    private var ended = false
    var finished: Bool { lock.withLock { ended } }
    var name: String { "slow" }
    var isRemote: Bool { false }
    init(seconds: Double) { self.seconds = seconds }
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] {
        try await Task.sleep(for: .seconds(seconds))
        lock.withLock { ended = true }
        return ["e1"]
    }
}

/// Ignores cancellation, like a model loop that never checks: it waits on its own `Thread`, not on a Swift
/// concurrency pool thread, so it does not starve other work; then answers `["e1"]`.
final class StubbornChooser: Choosing, @unchecked Sendable {
    let seconds: Double
    private let lock = NSLock()
    private var ended = false
    var finished: Bool { lock.withLock { ended } }
    var name: String { "stubborn" }
    var isRemote: Bool { false }
    init(seconds: Double) { self.seconds = seconds }
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread { [seconds] in
                Thread.sleep(forTimeInterval: seconds)
                c.resume()
            }
        }
        lock.withLock { ended = true }
        return ["e1"]
    }
}

actor PromptLog {
    var prompts: [ChoicePrompt] = []
    var responses: [Result<[String], ChoiceError>]
    init(_ responses: [Result<[String], ChoiceError>]) { self.responses = responses }
    func record(_ p: ChoicePrompt) -> Result<[String], ChoiceError> {
        prompts.append(p)
        return responses.isEmpty ? .success([]) : responses.removeFirst()
    }
}

/// Records every prompt; answers with `responses` in turn, then with no picks.
struct RecordingChooser: Choosing {
    let log: PromptLog
    var isRemote: Bool
    var name = "recording"
    init(responses: [Result<[String], ChoiceError>] = [], isRemote: Bool = false) {
        log = PromptLog(responses); self.isRemote = isRemote
    }
    func status() -> ModelStatus { .available }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] { try await log.record(prompt).get() }
    var prompts: [ChoicePrompt] { get async { await log.prompts } }
}

/// The on-device slot, filled by a `FixedChooser`.
struct FakeOnDevice: OnDeviceChooser {
    var inner: FixedChooser
    var name = "on-device"
    init(_ inner: FixedChooser) { self.inner = inner }
    func status() -> ModelStatus { inner.status() }
    func choose(_ prompt: ChoicePrompt) async throws -> [String] { try await inner.choose(prompt) }
}
