import Testing
import Foundation
@testable import SanketaCore

func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func tips(_ n: Int) -> [SearchItem] {
    (0..<n).map { SearchItem(packID: "p", packName: "P", kind: .tip, title: "t\($0)", detail: "", explain: nil, tags: []) }
}

struct TipStoreTests {
    @Test func tipStorePersistsAcrossInstances() throws {
        let url = try tempDir().appendingPathComponent("sub/tips.json")
        let a = TipStore(url: url)
        #expect(a.mark("x") == nil)
        a.set("x", .known); a.set("y", .less); a.set("z", .known); a.set("z", nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let b = TipStore(url: url)
        #expect(b.mark("x") == .known && b.mark("y") == .less && b.mark("z") == nil)
    }

    @Test func corruptFileGivesEmptyStore() throws {
        let url = try tempDir().appendingPathComponent("tips.json")
        try Data("not json".utf8).write(to: url)
        let s = TipStore(url: url)
        #expect(s.mark("x") == nil)
        s.set("x", .known)
        #expect(TipStore(url: url).mark("x") == .known)
    }

    @Test func pickExcludesKnown() throws {
        let s = TipStore(url: try tempDir().appendingPathComponent("t.json"))
        let items = tips(5)
        s.set(items[0].id, .known); s.set(items[3].id, .known)
        for seed in 0..<50 as Range<UInt64> {
            let p = s.pick(from: items, count: 5, seed: seed)
            #expect(Set(p.map(\.title)) == ["t1", "t2", "t4"] && p.count == 3)
        }
    }

    @Test func pickDeterministicForSeed() throws {
        let s = TipStore(url: try tempDir().appendingPathComponent("t.json"))
        let items = tips(10)
        let a = s.pick(from: items, count: 4, seed: 42)
        #expect(a == s.pick(from: items, count: 4, seed: 42))
        #expect(Set(a).count == 4)
        #expect((0..<20 as Range<UInt64>).contains { s.pick(from: items, count: 4, seed: $0) != a })
    }

    @Test func pickLessIsRarer() throws {
        let s = TipStore(url: try tempDir().appendingPathComponent("t.json"))
        let items = tips(4)
        s.set(items[0].id, .less)
        var counts = [String: Int]()
        for seed in 0..<1000 as Range<UInt64> {
            for p in s.pick(from: items, count: 1, seed: seed) { counts[p.title, default: 0] += 1 }
        }
        let normalAvg = Double(counts["t1", default: 0] + counts["t2", default: 0] + counts["t3", default: 0]) / 3
        #expect(Double(counts["t0", default: 0]) < 0.4 * normalAvg)
        #expect(counts["t0", default: 0] > 0)
    }
}
