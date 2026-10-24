import Foundation
import Testing

/// make variables reach recipes only after a check, so `make test FILTER=…` cannot run other commands.
@Suite struct MakefileGuardTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `make -n` prints the recipes and runs none; only `$(shell)` in a value could still run, so that is tested too.
    func make(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["-n", "-C", Self.repo.path] + args
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, o, e)
    }

    @Test func refusesUnsafeValues() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-pwned-\(UUID().uuidString)")
        for args in [["test", "FILTER=x';echo pwned;'"], ["test", "FILTER=$(shell touch \(marker.path))"], ["test", "FILTER=a b"],
                     ["lint", "PACKS=x;id"], ["shots", "SHOTS=`id`"], ["remote-setup", "HOST=me@gpubox;id"]] {
            let r = try make(args)
            #expect(r.status == 2, "\(args)")
            #expect(r.err.contains("has a character that is not safe") && !r.out.contains("swift") && !r.out.contains("pwned"), "\(args): \(r.out)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func safeValuesPassThroughTheEnvironment() throws {
        let r = try make(["test", "FILTER=PackLint", "lint", "PACKS=Resources/Packs/yazi.toml", "remote-setup", "HOST=me@gpubox"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains(#"swift test --filter "$FILTER""#) && r.out.contains(#"--lint-pack "$PACKS""#)
                && r.out.contains(#"scripts/remote-setup.sh "$HOST""#))
    }
}
