import Foundation

// Waits that suspend. A blocked thread of the Swift pool (Thread.sleep, a semaphore) stops other tests that run at
// the same time, and a test that runs the main run loop holds the main actor; these waits do neither.

/// Waits `s` seconds.
func pause(_ s: TimeInterval) async { try? await Task.sleep(for: .seconds(s)) }

/// Checks `ok` every `every` seconds for up to `s` seconds; true when it holds.
@discardableResult
func waitUntil(_ s: TimeInterval = 5, every: TimeInterval = 0.1, _ ok: () throws -> Bool) async rethrows -> Bool {
    let end = ContinuousClock.now + .seconds(s)
    while try !ok() {
        if ContinuousClock.now >= end { return false }
        await pause(every)
    }
    return true
}

/// Signals from any thread, such as a file-watcher callback; `next` waits for one.
final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiter: (id: UUID, c: CheckedContinuation<Bool, Never>)?

    func signal() {
        let c: CheckedContinuation<Bool, Never>? = lock.withLock {
            if let w = waiter { waiter = nil; return w.c }
            count += 1
            return nil
        }
        c?.resume(returning: true)
    }

    /// True when a signal came (or had come) within `timeout` seconds. One waiter at a time.
    func next(timeout: TimeInterval) async -> Bool {
        let id = UUID()
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let ready: Bool = lock.withLock {
                if count > 0 { count -= 1; return true }
                waiter = (id, c)
                return false
            }
            if ready { return c.resume(returning: true) }
            Task {
                await pause(timeout)
                let late: CheckedContinuation<Bool, Never>? = lock.withLock {
                    guard let w = waiter, w.id == id else { return nil }
                    waiter = nil
                    return w.c
                }
                late?.resume(returning: false)
            }
        }
    }
}

/// Runs the main run loop for `s` seconds and keeps the main actor all that time, so no other test's main-thread
/// work runs in it. Only for a CPU measurement of the main thread; to wait, use `pause` or `waitUntil`.
@MainActor func holdMain(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    let t = Timer(fire: end, interval: 0, repeats: false) { _ in }
    RunLoop.main.add(t, forMode: .default)
    while Date() < end { RunLoop.main.run(mode: .default, before: end) }
    t.invalidate()
}

/// Runs blocking work, such as a child process and its wait, on a GCD thread, so it holds no thread of the Swift pool
/// that other tests need.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in DispatchQueue.global().async { c.resume(with: Result { try work() }) } }
}
