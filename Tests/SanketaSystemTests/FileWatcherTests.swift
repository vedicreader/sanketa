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
}
