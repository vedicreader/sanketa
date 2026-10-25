import Testing
import Foundation
@testable import SanketaMLX
import SanketaCore
import SanketaAI

private let rt = PackMaker.App(name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee", version: "5.13")

/// A fake model for Make a Pack: it records what it gets and gives `answer`.
private final class PackRunner: PickRunner, @unchecked Sendable {
    let answer: String
    private let lock = NSLock()
    private var seen: [(user: String, schema: String, maxTokens: Int)] = []
    init(_ answer: String) { self.answer = answer }
    func run(_ prompt: ChoicePrompt, schema: String) async throws -> String { "" }
    func generate(system: String, user: String, schema: String, maxTokens: Int) async throws -> String {
        lock.withLock { seen.append((user, schema, maxTokens)) }
        return answer
    }
    func release() {}
    var calls: [(user: String, schema: String, maxTokens: Int)] { lock.withLock { seen } }
}

@Suite struct PackMakerMLXTests {
    /// Make a Pack waits for the model to load (search does not), and limits the answer to the JSON schema.
    @Test func makePackLoadsTheModelAndUsesTheSchema() async throws {
        let json = #"{"keys":[{"keys":"Ctrl+S","action":"Save the image","group":"Editor"}],"tips":[]}"#
        let runner = PackRunner(json)
        let c = MLXChooser(name: "on-device (fake)", key: UUID().uuidString, registry: Holders(), idle: 30, failedNote: "x",
                           available: { .available }, load: { runner })
        #expect(await !c.isLoaded)
        let prompt = PackMaker.promptB(app: rt, menu: [], docs: "Ctrl+S saves the image.", json: true)
        let answer = try await c.makePack(prompt)
        #expect(answer == json)
        let call = try #require(runner.calls.first)
        #expect(call.user == prompt && call.schema == PackMaker.jsonSchema && call.maxTokens == MLXChooser.packTokens)
        #expect(PackMaker.toml(json: answer, app: rt) != nil)
    }
}

// MARK: live, with a downloaded model (make test-mlx)

/// The first downloaded model that fits this Mac, when the MLX shaders are present.
private enum PackGate {
    static let installer = ModelInstaller(root: ModelCatalog.defaultRoot)
    static let spec = MLXModelChoice.allCases.map(ModelCatalog.spec).first {
        installer.isInstalled($0) && ProcessInfo.processInfo.physicalMemory >= $0.choice.minMemory
    }
    static var ready: Bool { spec != nil && MLXRuntime.isReady }
}

/// In the serialized live suite, so that it never runs while the search test measures the memory of the same model.
extension MLXChooserLiveTests {
    /// The real model writes JSON for docs text made from the RawTherapee pack; Sanketa makes it a pack with no lint error.
    @Test(.enabled(if: PackGate.ready), .timeLimit(.minutes(6))) func liveModelWritesAPackThatLints() async throws {
        let spec = try #require(PackGate.spec)
        let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Packs/rawtherapee.toml")
        let pack = try PackLibrary.decode(Data(contentsOf: packs))
        // docs in the words of the RawPedia page: "Ctrl+F2: go to the File Browser"
        let docs = pack.keys.map { k in
            "\(k.keys.replacingOccurrences(of: "⌃", with: "Ctrl+").replacingOccurrences(of: "⌥", with: "Alt+").replacingOccurrences(of: "⇧", with: "Shift+")): \(k.action) (\(k.group ?? ""))"
        }.joined(separator: "\n")
        let menu = [MenuShortcut(path: ["RawTherapee", "Quit RawTherapee"], keys: "⌘Q"), MenuShortcut(path: ["RawTherapee", "Hide RawTherapee"], keys: "⌘H")]
        let c = MLXChooser(spec: spec, installer: PackGate.installer, idle: 60)
        let t0 = ContinuousClock.now
        let answer = try await c.makePack(PackMaker.promptB(app: rt, menu: menu, docs: docs, json: true))
        let toml = try #require(PackMaker.toml(json: answer, app: rt), "not JSON: \(answer.prefix(300))")
        let r = try #require(PackMaker.process(toml, app: rt, menu: menu))
        print("live pack (\(spec.choice.displayName)): \(ContinuousClock.now - t0), \(r.keyCount) keys, \(r.styleFixes) style fixes, findings \(r.findings)")
        print(r.text.prefix(1200))
        #expect(r.errors.isEmpty, "\(r.errors)")
        #expect(r.keyCount >= 5)
        await MLXChooser.unloadAll()
    }
}
