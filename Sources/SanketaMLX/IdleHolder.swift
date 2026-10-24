import Foundation

/// Holds a value that is costly to load, such as a model. It loads on first use, and concurrent first uses share one
/// load. After `idle` seconds with no use running, it drops the value and calls `unload`.
public actor IdleHolder<Value: Sendable> {
    let idle: TimeInterval
    let load: @Sendable () async throws -> Value
    let unload: @Sendable (Value) -> Void
    private var value: Value?
    private var loading: Task<Value, Error>?
    private var active = 0
    private var timer: Task<Void, Never>?
    /// Goes up at each use, so a timer that fires late after a newer use does nothing.
    private var generation = 0
    private var dropAfterUse = false

    public init(idle: TimeInterval, load: @escaping @Sendable () async throws -> Value,
                unload: @escaping @Sendable (Value) -> Void = { _ in }) {
        self.idle = idle; self.load = load; self.unload = unload
    }

    public var isLoaded: Bool { value != nil }
    public var isLoading: Bool { loading != nil }

    /// Unloads now; while a use runs, as soon as the last one ends. A load that runs goes on.
    public func drop() {
        generation += 1
        timer?.cancel(); timer = nil
        if active > 0 { dropAfterUse = true; return }
        guard let v = value else { return }
        value = nil
        unload(v)
    }

    /// Runs `body` with the value, off this actor. The idle timer starts again when the last running use ends.
    public func use<R: Sendable>(_ body: @Sendable (Value) async throws -> R) async throws -> R {
        generation += 1
        timer?.cancel(); timer = nil
        active += 1
        defer {
            active -= 1
            if active == 0 { if dropAfterUse { dropAfterUse = false; drop() } else { arm() } }
        }
        return try await body(try await obtain())
    }

    private func obtain() async throws -> Value {
        if let value { return value }
        if let loading { return try await loading.value }
        let t = Task { [load] in try await load() }
        loading = t
        do {
            let v = try await t.value
            value = v
            loading = nil
            return v
        } catch {
            loading = nil
            throw error
        }
    }

    private func arm() {
        guard value != nil else { return }
        let gen = generation, idle = idle
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(idle))
            if Task.isCancelled { return }
            await self?.expire(gen)
        }
    }

    private func expire(_ gen: Int) {
        guard gen == generation, active == 0, let v = value else { return }
        value = nil; timer = nil
        unload(v)
    }
}
