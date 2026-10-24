import Testing
import Foundation
@testable import SanketaMLX

/// Counts loads and unloads.
final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var l = 0, u = 0
    func loaded() -> Int { lock.withLock { l += 1; return l } }
    func unloaded() { lock.withLock { u += 1 } }
    var loads: Int { lock.withLock { l } }
    var unloads: Int { lock.withLock { u } }
}

private struct LoadFailed: Error {}

@Suite struct IdleHolderTests {
    @Test func holderLoadsOnceAndUnloadsWhenIdle() async throws {
        let n = Counts()
        let h = IdleHolder<Int>(idle: 0.3, load: { try await Task.sleep(for: .milliseconds(100)); return n.loaded() },
                                unload: { _ in n.unloaded() })
        async let a = h.use { $0 }
        async let b = h.use { $0 }
        #expect(try await [a, b] == [1, 1])
        #expect(n.loads == 1 && n.unloads == 0)
        #expect(await h.isLoaded)
        try await Task.sleep(for: .milliseconds(600))
        #expect(await !h.isLoaded)
        #expect(n.unloads == 1)
        #expect(try await h.use { $0 } == 2)
        #expect(n.loads == 2)
    }

    @Test func holderUseKeepsItLoaded() async throws {
        let n = Counts()
        let h = IdleHolder<Int>(idle: 0.3, load: { n.loaded() }, unload: { _ in n.unloaded() })
        for _ in 0..<5 {
            _ = try await h.use { $0 }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(n.loads == 1 && n.unloads == 0)
        #expect(await h.isLoaded)
    }

    @Test func longUseIsNotUnloaded() async throws {
        let n = Counts()
        let h = IdleHolder<Int>(idle: 0.2, load: { n.loaded() }, unload: { _ in n.unloaded() })
        _ = try await h.use { _ in try await Task.sleep(for: .milliseconds(600)) }
        #expect(n.unloads == 0)
        #expect(await h.isLoaded)
        try await Task.sleep(for: .milliseconds(500))
        #expect(n.unloads == 1)
    }

    @Test func failedLoadIsTriedAgain() async throws {
        let n = Counts()
        let h = IdleHolder<Int>(idle: 0.2, load: { if n.loaded() == 1 { throw LoadFailed() }; return 7 })
        await #expect(throws: LoadFailed.self) { try await h.use { $0 } }
        #expect(await !h.isLoaded)
        #expect(try await h.use { $0 } == 7)
        #expect(n.loads == 2)
    }
}
