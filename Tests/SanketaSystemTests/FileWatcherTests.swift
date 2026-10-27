import Foundation
import Testing
@testable import SanketaSystem

/// Real files in a temp dir: in-place writes (how Python's write_text saves keys.json), atomic replaces, delete and re-create.
@Suite struct FileWatcherTests {
    @Test func reportsWritesReplacesAndRecreation() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("keys.json")
        try Data("{}".utf8).write(to: f)
        let hit = Signals()
        let w = FileWatcher(url: f, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }

        let h = try FileHandle(forWritingTo: f)              // in place: same inode
        try h.truncate(atOffset: 0); try h.write(contentsOf: Data(#"{"keys": {}}"#.utf8)); try h.close()
        #expect(await hit.next(timeout: 10), "in-place write")

        try Data(#"{"keys": {"a": "b"}}"#.utf8).write(to: f, options: .atomic)     // new inode via rename
        #expect(await hit.next(timeout: 10), "atomic replace")

        let h2 = try FileHandle(forWritingTo: f)             // the watch moved to the new inode
        try h2.seekToEnd(); try h2.write(contentsOf: Data(" ".utf8)); try h2.close()
        #expect(await hit.next(timeout: 10), "write after replace")

        try FileManager.default.moveItem(at: f, to: d.appendingPathComponent("old.json"))
        #expect(await hit.next(timeout: 10), "moved away")
        try Data("{}".utf8).write(to: f)
        #expect(await hit.next(timeout: 10), "created again")
    }

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-watch-\(UUID().uuidString)/packs")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A packs folder: new files, in-place saves of a pack, atomic saves and removal each report once.
    @Test func watchesEveryPackInAFolder() async throws {
        let d = try folder()
        let a = d.appendingPathComponent("a.toml")
        try Data("id = \"a\"".utf8).write(to: a)
        let hit = Signals()
        let w = FileWatcher(url: d, children: "toml", delay: 0.3, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }

        let h = try FileHandle(forWritingTo: a)              // in place: the folder does not change
        try h.seekToEnd(); try h.write(contentsOf: Data("\nname = \"A\"".utf8)); try h.close()
        #expect(await hit.next(timeout: 10), "in-place save of a pack")

        let b = d.appendingPathComponent("b.toml")
        try Data("id = \"b\"".utf8).write(to: b, options: .atomic)
        #expect(await hit.next(timeout: 10), "new pack")

        let hb = try FileHandle(forWritingTo: b)             // the new file is watched too
        try hb.seekToEnd(); try hb.write(contentsOf: Data(" ".utf8)); try hb.close()
        #expect(await hit.next(timeout: 10), "in-place save of the new pack")

        try FileManager.default.moveItem(at: a, to: d.deletingLastPathComponent().appendingPathComponent("a.toml"))
        #expect(await hit.next(timeout: 10), "pack moved away")
    }

    /// config.toml sits next to the packs folder: saving it must not reload the packs.
    @Test func ignoresSiblingsOfTheWatchedFolder() async throws {
        let d = try folder()
        try Data("id = \"a\"".utf8).write(to: d.appendingPathComponent("a.toml"))
        let hit = Signals()
        let w = FileWatcher(url: d, children: "toml", delay: 0.1, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }
        let config = d.deletingLastPathComponent().appendingPathComponent("config.toml")
        try Data("hotkey = \"ctrl+opt+k\"".utf8).write(to: config, options: .atomic)
        try Data("hotkey = \"ctrl+opt+j\"".utf8).write(to: config, options: .atomic)
        #expect(await !hit.next(timeout: 1), "a config.toml save reloaded the packs")
        try Data("id = \"b\"".utf8).write(to: d.appendingPathComponent("b.toml"), options: .atomic)
        #expect(await hit.next(timeout: 10), "a new pack still reloads")
    }

    /// An editor's save is a burst of events; the watcher reports it once, after the debounce.
    @Test func debouncesABurst() async throws {
        let d = try folder()
        let a = d.appendingPathComponent("a.toml")
        try Data("x".utf8).write(to: a)
        let lock = NSLock()
        var hits = [Date]()
        let w = FileWatcher(url: d, children: "toml", delay: 0.5, callbackQueue: DispatchQueue(label: "test")) {
            lock.withLock { hits.append(Date()) }
        }
        defer { withExtendedLifetime(w) {} }
        let start = Date()
        // the five writes go back to back, so even a busy Mac keeps them inside one 0.5 s delay
        for i in 0..<5 {
            let h = try FileHandle(forWritingTo: a)
            try h.seekToEnd(); try h.write(contentsOf: Data("\(i)".utf8)); try h.close()
        }
        // wait for the first callback (up to 5 s on a busy Mac), then for any late one
        for _ in 0..<100 where lock.withLock({ hits.isEmpty }) { await pause(0.05) }
        await pause(1.0)
        let got = lock.withLock { hits }
        // a loaded machine can split the burst once; it must never report each write
        #expect((1...2).contains(got.count), "\(got.count) callbacks for 5 writes")
        #expect((got.first?.timeIntervalSince(start) ?? 0) >= 0.5)
    }
}
