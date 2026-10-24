import Foundation

public enum TipMark: String, Codable { case known, less }

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

public final class TipStore {
    let url: URL
    var marks: [String: TipMark]

    public init(url: URL) {
        self.url = url
        marks = (try? JSONDecoder().decode([String: TipMark].self, from: Data(contentsOf: url))) ?? [:]
    }

    public func mark(_ id: String) -> TipMark? { marks[id] }

    public func ids(marked m: TipMark) -> Set<String> { Set(marks.filter { $0.value == m }.keys) }

    public func set(_ id: String, _ mark: TipMark?) {
        marks[id] = mark
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try? enc.encode(marks).write(to: url, options: .atomic)
    }

    /// Weighted draw without replacement: `.known` excluded, `.less` weighs 0.25, others 1.
    public func pick(from items: [SearchItem], count: Int, seed: UInt64) -> [SearchItem] {
        var pool = items.filter { marks[$0.id] != .known }.map { ($0, marks[$0.id] == .less ? 0.25 : 1.0) }
        var rng = SplitMix64(state: seed)
        var out: [SearchItem] = []
        while out.count < count, !pool.isEmpty {
            var r = rng.unit() * pool.reduce(0) { $0 + $1.1 }
            let idx = pool.firstIndex { r -= $0.1; return r < 0 } ?? pool.count - 1
            out.append(pool.remove(at: idx).0)
        }
        return out
    }
}
