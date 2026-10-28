import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// The keymaps folder as the app watches it: an app rewrites its file atomically (a temp file, then a rename), and the
/// next read of the folder gives the new keys. Temp folders only.
@Suite struct KeymapWatchTests {
    static func doc(_ chord: String) -> String {
        #"{"version": 1, "app": "demo", "name": "demo", "contexts": [{"id": "idle", "label": "Waiting"}], "keys": ["#
            + #"{"action": "fold", "chords": ["\#(chord)"], "label": "Fold the rows", "group": "Turn"}]}"#
    }

    static func library(_ folder: URL) -> PackLibrary {
        var lib = PackLibrary(packs: ["demo": Pack(id: "demo", name: "demo", processes: ["demo"], keys: [KeyEntry(keys: "⌃O", action: "Fold")])])
        AppKeymap.apply(to: &lib, folder: folder)
        return lib
    }

    /// Writes `text` the way ramabana's atomic save does: a hidden temp file in the folder, renamed over the file.
    static func atomicWrite(_ text: String, to f: URL) throws {
        let tmp = f.deletingLastPathComponent().appendingPathComponent(".\(f.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: tmp)
        _ = try FileManager.default.replaceItemAt(f, withItemAt: tmp)
    }

    @Test func aRewriteGivesTheNewKeys() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-keymapwatch-\(UUID().uuidString)")
        let d = root.appendingPathComponent("keymaps")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("demo.json")
        try Data(Self.doc("alt+o").utf8).write(to: f)
        #expect(Self.library(d).packs["demo"]?.keys.map(\.keys) == ["⌥O"])

        let hit = Signals()
        let w = FileWatcher(url: d, children: "json", delay: 0.3, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }
        try Self.atomicWrite(Self.doc("alt+p"), to: f)
        #expect(await hit.next(timeout: 10), "atomic rewrite")
        #expect(Self.library(d).packs["demo"]?.keys.map(\.keys) == ["⌥P"])

        let h = try FileHandle(forWritingTo: f)                // an in-place write of the new file is seen too
        try h.truncate(atOffset: 0); try h.write(contentsOf: Data(Self.doc("ctrl+o").utf8)); try h.close()
        #expect(await hit.next(timeout: 10), "in-place write")
        #expect(Self.library(d).packs["demo"]?.keys.map(\.keys) == ["⌃O"])

        try FileManager.default.removeItem(at: f)             // no file: the pack's own keys again
        #expect(await hit.next(timeout: 10), "removed")
        #expect(Self.library(d).packs["demo"]?.keys.map(\.action) == ["Fold"])
    }

    /// The folder can be made after Sanketa starts: the first file in it still counts.
    @Test func aFolderMadeLaterIsSeen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-keymapwatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let d = root.appendingPathComponent("keymaps")
        let hit = Signals()
        let w = FileWatcher(url: d, children: "json", delay: 0.3, callbackQueue: DispatchQueue(label: "test")) { hit.signal() }
        defer { withExtendedLifetime(w) {} }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        #expect(await hit.next(timeout: 10), "folder made")
        try Self.atomicWrite(Self.doc("alt+o"), to: d.appendingPathComponent("demo.json"))
        #expect(await hit.next(timeout: 10), "first file")
        #expect(Self.library(d).packs["demo"]?.keys.map(\.keys) == ["⌥O"])
    }
}
