import Foundation
import Testing
@testable import SanketaSystem

/// Real files in a temp dir: in-place writes (how Python's write_text saves keys.json), atomic replaces, delete and re-create.
@Suite struct FileWatcherTests {
    @Test func reportsWritesReplacesAndRecreation() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("keys.json")
        try Data("{}".utf8).write(to: f)
        let hit = DispatchSemaphore(value: 0)
        let w = FileWatcher(url: f, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }

        let h = try FileHandle(forWritingTo: f)              // in place: same inode
        try h.truncate(atOffset: 0); try h.write(contentsOf: Data(#"{"keys": {}}"#.utf8)); try h.close()
        #expect(hit.wait(timeout: .now() + 3) == .success, "in-place write")

        try Data(#"{"keys": {"a": "b"}}"#.utf8).write(to: f, options: .atomic)     // new inode via rename
        #expect(hit.wait(timeout: .now() + 3) == .success, "atomic replace")

        let h2 = try FileHandle(forWritingTo: f)             // the watch moved to the new inode
        try h2.seekToEnd(); try h2.write(contentsOf: Data(" ".utf8)); try h2.close()
        #expect(hit.wait(timeout: .now() + 3) == .success, "write after replace")

        try FileManager.default.moveItem(at: f, to: d.appendingPathComponent("old.json"))
        #expect(hit.wait(timeout: .now() + 3) == .success, "moved away")
        try Data("{}".utf8).write(to: f)
        #expect(hit.wait(timeout: .now() + 3) == .success, "created again")
    }

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-watch-\(UUID().uuidString)/packs")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A packs folder: new files, in-place saves of a pack, atomic saves and removal each report once.
    @Test func watchesEveryPackInAFolder() throws {
        let d = try folder()
        let a = d.appendingPathComponent("a.toml")
        try Data("id = \"a\"".utf8).write(to: a)
        let hit = DispatchSemaphore(value: 0)
        let w = FileWatcher(url: d, children: "toml", delay: 0.3, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }

        let h = try FileHandle(forWritingTo: a)              // in place: the folder does not change
        try h.seekToEnd(); try h.write(contentsOf: Data("\nname = \"A\"".utf8)); try h.close()
        #expect(hit.wait(timeout: .now() + 3) == .success, "in-place save of a pack")

        let b = d.appendingPathComponent("b.toml")
        try Data("id = \"b\"".utf8).write(to: b, options: .atomic)
        #expect(hit.wait(timeout: .now() + 3) == .success, "new pack")

        let hb = try FileHandle(forWritingTo: b)             // the new file is watched too
        try hb.seekToEnd(); try hb.write(contentsOf: Data(" ".utf8)); try hb.close()
        #expect(hit.wait(timeout: .now() + 3) == .success, "in-place save of the new pack")

        try FileManager.default.moveItem(at: a, to: d.deletingLastPathComponent().appendingPathComponent("a.toml"))
        #expect(hit.wait(timeout: .now() + 3) == .success, "pack moved away")
    }

    /// An editor's save is a burst of events; the watcher reports it once, after the debounce.
    @Test func debouncesABurst() throws {
        let d = try folder()
        let a = d.appendingPathComponent("a.toml")
        try Data("x".utf8).write(to: a)
        let lock = NSLock()
        var hits = [Date]()
        let w = FileWatcher(url: d, children: "toml", delay: 0.3, callbackQueue: DispatchQueue(label: "test")) {
            lock.withLock { hits.append(Date()) }
        }
        defer { withExtendedLifetime(w) {} }
        let start = Date()
        for i in 0..<5 {
            let h = try FileHandle(forWritingTo: a)
            try h.seekToEnd(); try h.write(contentsOf: Data("\(i)".utf8)); try h.close()
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 1.0)
        let got = lock.withLock { hits }
        #expect(got.count == 1, "\(got.count) callbacks")
        #expect((got.first?.timeIntervalSince(start) ?? 0) >= 0.3)
    }
}
