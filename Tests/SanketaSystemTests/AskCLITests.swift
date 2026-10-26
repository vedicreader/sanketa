import Foundation
import Testing
import SanketaCore

private final class Marker {}

/// The real `Sanketa --ask` binary, with HOME, the model folder and the Leela keymap in a temp dir, so it reads no real
/// config, model or Keychain item; `[llm] openai` stays off, so nothing leaves the machine.
@Suite struct AskCLITests {
    static let bin = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Sanketa")

    func run(_ args: [String], config: String? = nil) throws -> (out: String?, file: [String]) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent(".config/sanketa"), withIntermediateDirectories: true)
        if let config { try config.write(to: d.appendingPathComponent(".config/sanketa/config.toml"), atomically: true, encoding: .utf8) }
        let out = d.appendingPathComponent("ask.txt")
        let env = ["HOME=\(d.path)", "SANKETA_MODEL_DIR=\(d.path)/models", "LEELA_KEYMAP=\(d.path)/keys.json", "OPENAI_API_KEY="]
        let s = ProcessRunner().run("/usr/bin/env", env + [Self.bin.path] + args + ["--out", out.path], timeout: 60)
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        return (s, text.split(separator: "\n").map(String.init))
    }

    @Test func askPrintsBackendAndResults() throws {
        let r = try run(["--ask", "how do I split the window side by side"])
        #expect(r.out != nil, "exit status was not 0")
        let first = try #require(r.file.first)
        #expect(first.hasPrefix("backend: "))
        #expect(r.file.count >= 2 && r.file.count <= 6)
        #expect(r.file.dropFirst().contains { $0.hasPrefix("tmux:") || $0.hasPrefix("*tmux:") }, "\(r.file)")
        #expect(r.file.dropFirst().allSatisfy { $0.contains(": ") && $0.contains(" · ") })
    }

    @Test func askWithModelsOffSaysPlainSearch() throws {
        let r = try run(["--ask", "how do I split the window side by side"],
                        config: "[llm]\non_device = false\napple_fm = false\n")
        #expect(r.file.first == "backend: Plain search: no model turned on")
        #expect(r.file.dropFirst().allSatisfy { !$0.hasPrefix("*") })
        #expect(r.file.dropFirst().contains { $0.hasPrefix("tmux:") }, "\(r.file)")
    }

    @Test func installModelRefusesUnknownSize() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-install-\(UUID().uuidString)")
        let s = ProcessRunner().run("/usr/bin/env", ["HOME=\(d.path)", "SANKETA_MODEL_DIR=\(d.path)/models", Self.bin.path,
                                                     "--install-model", "9b"], timeout: 10)
        #expect(s == nil)   // exit 2, before any request
        #expect(!FileManager.default.fileExists(atPath: d.appendingPathComponent("models").path))
    }
}
