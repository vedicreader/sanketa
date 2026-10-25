import Foundation

/// Runs blocking work, such as a child process and its wait, on a GCD thread, so it holds no thread of the Swift pool
/// that other tests need.
func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in DispatchQueue.global().async { c.resume(with: Result { try work() }) } }
}
