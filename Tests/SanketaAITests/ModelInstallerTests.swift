import Testing
import Foundation
import CryptoKit
@testable import SanketaAI
import SanketaCore

private let rev = "0123456789abcdef0123456789abcdef01234567"
private let weights = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
private let config = Data(#"{"model_type":"tiny"}"#.utf8)

private func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
private func file(_ name: String, _ d: Data) -> ModelFile { ModelFile(name: name, size: Int64(d.count), sha256: hex(d)) }
private let spec = ModelSpec(choice: .qwen2b, repo: "test/tiny", revision: rev, folder: "Tiny",
                             files: [file("model.safetensors", weights), file("config.json", config)])
private func path(_ name: String) -> String { "/test/tiny/resolve/\(rev)/\(name)" }
private func good() -> [String: [(Int, Data)]] { [path("model.safetensors"): [(200, weights)], path("config.json"): [(200, config)]] }

private func modelTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

private func installError(_ body: () async throws -> Void) async -> InstallError? {
    do { try await body(); return nil } catch let e as InstallError { return e } catch { return nil }
}

/// Progress values seen, in order.
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int64, Int64)] = []
    func add(_ done: Int64, _ total: Int64) { lock.withLock { values.append((done, total)) } }
    var all: [(Int64, Int64)] { lock.withLock { values } }
}

@Suite struct ModelInstallerTests {
    @Test func installVerifiesAndMarks() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session)
        #expect(!inst.isInstalled(spec))
        let seen = Seen()
        try await inst.install(spec) { seen.add($0, $1) }
        #expect(inst.isInstalled(spec))
        let dir = inst.directory(spec)
        #expect(dir == root.appendingPathComponent("Tiny"))
        #expect(try Data(contentsOf: dir.appendingPathComponent("model.safetensors")) == weights)
        #expect(try Data(contentsOf: dir.appendingPathComponent("config.json")) == config)
        #expect(try String(contentsOf: dir.appendingPathComponent(".verified"), encoding: .utf8) == rev)
        #expect(!exists(root.appendingPathComponent("Tiny.partial")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Tiny"])
        let last = try #require(seen.all.last)
        #expect(last == (spec.downloadSize, spec.downloadSize))
        #expect(seen.all.allSatisfy { $0.0 <= $0.1 && $0.1 == spec.downloadSize })
        #expect(zip(seen.all, seen.all.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        // model files are data: nobody may run them
        for f in spec.files {
            let p = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(f.name).path)[.posixPermissions] as? Int
            #expect(p.map { $0 & 0o111 } == 0)
        }
        #expect(stub.requests.map { $0.url?.absoluteString } == spec.files.map { spec.url($0).absoluteString })
        #expect(stub.requests.allSatisfy { $0.header("Authorization") == nil && $0.method == "GET" && $0.body.isEmpty })
    }

    @Test func badHashLeavesNothingInstalled() async throws {
        let root = try modelTempDir()
        var bad = weights
        bad[1000] ^= 0xff   // same size, other bytes
        var answers = good()
        answers[path("model.safetensors")] = [(200, bad)]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .badHash("model.safetensors"))
        #expect(!inst.isInstalled(spec))
        #expect(!exists(root.appendingPathComponent("Tiny")) && !exists(root.appendingPathComponent("Tiny.partial")))
    }

    @Test func badSizeIsRefused() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("config.json")] = [(200, config + Data("x".utf8))]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .badSize("config.json"))
        #expect(!inst.isInstalled(spec) && !exists(root.appendingPathComponent("Tiny.partial")))
    }

    @Test func interruptedDownloadIsNotInstalled() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("config.json")] = [(500, Data("oops".utf8)), (200, config)]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .http("config.json", 500))
        #expect(!inst.isInstalled(spec))
        #expect(!exists(root.appendingPathComponent("Tiny")) && !exists(root.appendingPathComponent("Tiny.partial")))
        // a later run starts clean and downloads every file again
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(stub.requests.count == 4)
    }

    @Test func stalePartialFolderIsReplaced() async throws {
        let root = try modelTempDir()
        let partial = root.appendingPathComponent("Tiny.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: partial.appendingPathComponent("model.safetensors"))
        try rev.write(to: partial.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session)
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
        #expect(!exists(partial))
    }

    @Test func reinstallReplacesOldFolder() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session)
        let dir = inst.directory(spec)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("leftover.bin"))
        #expect(!inst.isInstalled(spec))
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(!exists(dir.appendingPathComponent("leftover.bin")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Tiny"])
    }

    @Test func wrongSizeIsNotInstalled() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session)
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        let h = try FileHandle(forWritingTo: inst.directory(spec).appendingPathComponent("model.safetensors"))
        try h.truncate(atOffset: 1000)
        try h.close()
        #expect(!inst.isInstalled(spec))
    }

    @Test func otherRevisionIsNotInstalled() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session)
        try await inst.install(spec) { _, _ in }
        let newer = ModelSpec(choice: spec.choice, repo: spec.repo, revision: String(repeating: "f", count: 40),
                              folder: spec.folder, files: spec.files)
        #expect(!inst.isInstalled(newer))
    }

    @Test func removeDeletesFolder() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session)
        try await inst.install(spec) { _, _ in }
        try inst.remove(spec)
        #expect(!inst.isInstalled(spec))
        #expect(!exists(inst.directory(spec)))
        try inst.remove(spec)   // nothing there: no error
    }

    @Test func tooLittleSpaceDownloadsNothing() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in 1000 })
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .noSpace(need: ModelInstaller.needed(spec.downloadSize), free: 1000))
        #expect(stub.requests.isEmpty && !inst.isInstalled(spec) && !exists(root.appendingPathComponent("Tiny.partial")))
    }

    @Test func secondInstallIsBusyAndCancelLeavesNothing() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        stub.hold = { p in if p.hasSuffix("/config.json") { entered.signal(); release.wait() } }
        let inst = ModelInstaller(root: root, session: stub.session)
        let first = Task { try await inst.install(spec) { _, _ in } }
        // wait off the cooperative pool until the second file's request is open
        await withCheckedContinuation { c in DispatchQueue.global().async { entered.wait(); c.resume() } }
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .busy)
        first.cancel()
        release.signal()
        let r = await first.result
        #expect(throws: CancellationError.self) { try r.get() }
        #expect(!inst.isInstalled(spec))
        #expect(!exists(root.appendingPathComponent("Tiny")) && !exists(root.appendingPathComponent("Tiny.partial")))
        // no longer busy
        stub.hold = nil
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
    }

    @Test(arguments: ["http://cas-bridge.xethub.hf.co/w", "https://evil.example/w", "https://evilhf.co/w",
                      "https://hf.co.evil.example/w"])
    func redirectOffHFIsRefused(_ to: String) async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("model.safetensors")] = [(302, Data(to.utf8))]
        answers["/w"] = [(200, weights)]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session)
        let u = try #require(URL(string: to))
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .redirectRefused("\(u.scheme!)://\(u.host!)"))
        #expect(!inst.isInstalled(spec))
        #expect(!exists(root.appendingPathComponent("Tiny")) && !exists(root.appendingPathComponent("Tiny.partial")))
        #expect(stub.requests.allSatisfy { $0.url?.host == "huggingface.co" })
    }

    @Test func redirectToHFCDNIsFollowed() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("model.safetensors")] = [(302, Data("https://cas-bridge.xethub.hf.co/xet/w".utf8))]
        answers["/xet/w"] = [(200, weights)]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session)
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(stub.requests.contains { $0.url?.absoluteString == "https://cas-bridge.xethub.hf.co/xet/w" })
    }

    @Test func spaceCheckKeepsHeadroom() async throws {
        #expect(ModelInstaller.needed(10_000_000_000) == 10_500_000_000)
        #expect(ModelInstaller.needed(1000) == 1000 + 256 << 20)
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let free = spec.downloadSize + 1000   // fits the files, not the headroom
        let inst = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in free })
        #expect(await installError { try await inst.install(spec) { _, _ in } }
                == .noSpace(need: spec.downloadSize + 256 << 20, free: free))
        #expect(stub.requests.isEmpty)
    }

    @Test func noSpaceForReinstallKeepsOldInstall() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        try await ModelInstaller(root: root, session: stub.session).install(spec) { _, _ in }
        // the old folder stays until the new one is in place, so it frees nothing
        let inst = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in 100 << 20 })
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .noSpace(need: spec.downloadSize + 256 << 20, free: 100 << 20))
        #expect(inst.isInstalled(spec))
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
        #expect(stub.requests.count == 2)
    }

    @Test func lostConnectionIsNetworkError() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        stub.failure = { $0.hasSuffix("/config.json") ? URLError(.networkConnectionLost) : nil }
        let inst = ModelInstaller(root: root, session: stub.session)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .network("config.json", "The connection stopped."))
        #expect(!inst.isInstalled(spec) && !exists(root.appendingPathComponent("Tiny.partial")))
        // a cancel that did not come from us is not a CancellationError
        stub.failure = { _ in URLError(.cancelled) }
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .network("model.safetensors", "The download stopped."))
    }

    @Test func defaultSessionKeepsNothing() {
        let c = ModelInstaller.makeSession().configuration
        #expect(c.httpCookieStorage == nil && c.urlCredentialStorage == nil && c.urlCache == nil && !c.httpShouldSetCookies)
    }

    @Test func catalogPinsMatchHFLayout() throws {
        let names = ["config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json",
                     "tokenizer_config.json", "chat_template.jinja"]
        let hex40 = try Regex("^[0-9a-f]{40}$"), hex64 = try Regex("^[0-9a-f]{64}$")
        for (c, gb) in [(MLXModelChoice.qwen4b, 3.06), (.qwen2b, 1.75)] {
            let s = ModelCatalog.spec(c)
            #expect(s.choice == c)
            #expect(s.revision.wholeMatch(of: hex40) != nil)
            #expect(s.folder == String(s.repo.split(separator: "/").last!))
            #expect(Set(s.files.map(\.name)) == Set(names) && s.files.count == names.count)
            for f in s.files {
                #expect(s.url(f).scheme == "https" && s.url(f).host == "huggingface.co")
                #expect(s.url(f).absoluteString == "https://huggingface.co/\(s.repo)/resolve/\(s.revision)/\(f.name)")
                #expect(f.sha256.wholeMatch(of: hex64) != nil)
                #expect(f.size > 0)
            }
            #expect(abs(Double(s.downloadSize) / 1e9 - gb) <= gb * 0.01)
        }
        #expect(ModelCatalog.spec(.qwen4b).repo == "mlx-community/Qwen3.5-4B-MLX-4bit")
        #expect(ModelCatalog.spec(.qwen2b).repo == "mlx-community/Qwen3.5-2B-MLX-4bit")
    }

    @Test func defaultRootHonoursEnv() {
        #expect(ModelCatalog.defaultRoot(env: ["SANKETA_MODEL_DIR": "/tmp/x"]).path == "/tmp/x")
        #expect(ModelCatalog.defaultRoot(env: [:]).path.hasSuffix("/Library/Application Support/Sanketa/Models"))
    }

    /// Reads (never writes) the bench copies downloaded and checked on 2026-10-24, when they are there. The small
    /// files are hashed; the weights are checked by size only, so the test stays fast.
    @Test func catalogMatchesBenchCopies() throws {
        let bench = URL(fileURLWithPath: "/tmp/sanketa-bench/models")
        for (c, dir) in [(MLXModelChoice.qwen4b, "qwen35-4b-dl"), (.qwen2b, "qwen35-2b")] {
            let d = bench.appendingPathComponent(dir)
            guard exists(d.appendingPathComponent("config.json")) else { continue }
            for f in ModelCatalog.spec(c).files {
                let u = d.appendingPathComponent(f.name)
                let size = try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64
                #expect(size == f.size, "\(dir)/\(f.name)")
                if f.size < 50_000_000 { #expect(try ModelInstaller.sha256(of: u) == f.sha256, "\(dir)/\(f.name)") }
            }
        }
    }
}
