import Foundation
import Testing

private final class Marker {}

/// The real `Sanketa --lint-pack` binary on packs in a temp dir.
@Suite struct LintCLITests {
    static let bin = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Sanketa")

    func lint(_ args: [String]) throws -> (status: Int32, out: [String]) {
        let p = Process(), out = Pipe()
        p.executableURL = Self.bin
        p.arguments = ["--lint-pack"] + args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, s.split(separator: "\n").map(String.init))
    }

    func dir(_ files: [String: String]) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (n, c) in files { try c.write(to: d.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        return d
    }

    @Test func failsOnErrorsWithOneLinePerFinding() throws {
        let d = try dir([
            "yazi.toml": "id = \"yazi\"\nname = \"yazi\"\nproccesses = [\"yazi\"]\n\n[[keys]]\nkeys = \"C-d\"\naction = \"Half page down\"\n",
            "good.toml": "id = \"good\"\nname = \"Good\"\nprocesses = [\"good\"]\n\n[[keys]]\nkeys = \"⌃D\"\naction = \"Quit\"\n",
            "notes.txt": "not a pack",
        ])
        let r = try lint([d.path])
        #expect(r.status == 1)
        #expect(r.out == ["yazi.toml: the pack: unknown field proccesses. Did you mean processes?",
                          "yazi.toml: key 1 (C-d): write ⌃D",
                          "yazi.toml: warning: the pack has no processes, match, apps or titles, so only search shows it",
                          "2 files: 2 errors, 1 warning"])
        let ok = try lint([d.appendingPathComponent("good.toml").path])
        #expect(ok.status == 0 && ok.out == ["1 file: 0 errors, 0 warnings"])
    }

    @Test func usageErrors() throws {
        #expect(try lint([]).status == 2)
        #expect(try lint(["/nonexistent/sanketa-\(UUID().uuidString).toml"]).status == 2)
    }
}
