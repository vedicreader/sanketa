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

/// Short waits between tries, so tests of failures stay fast.
private let fast: [TimeInterval] = [0.01, 0.01, 0.01, 0.01]

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
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
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
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .badHash("model.safetensors"))
        #expect(!inst.isInstalled(spec))
        // the bad file goes; the folder stays for the next try
        #expect(!exists(root.appendingPathComponent("Tiny")) && !exists(root.appendingPathComponent("Tiny.partial/model.safetensors")))
    }

    @Test func badSizeIsRefused() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("config.json")] = [(200, config + Data("x".utf8))]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .badSize("config.json"))
        #expect(!inst.isInstalled(spec) && !exists(root.appendingPathComponent("Tiny.partial/config.json")))
    }

    @Test func serverErrorIsTriedAgain() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("config.json")] = [(500, Data("oops".utf8)), (200, config)]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(stub.requests.map { $0.url?.lastPathComponent } == ["model.safetensors", "config.json", "config.json"])
    }

    @Test func notFoundIsNotTriedAgain() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("config.json")] = [(404, Data("no".utf8))]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .http("config.json", 404))
        #expect(!inst.isInstalled(spec) && stub.requests.count == 2)
        // the whole first file stays; a later run checks it again and asks only for the second
        let fixed = Stub(data: good())
        try await ModelInstaller(root: root, session: fixed.session, backoff: fast).install(spec) { _, _ in }
        #expect(fixed.requests.map { $0.url?.lastPathComponent } == ["config.json"])
    }

    @Test func stallMidFileGoesOnWithRange() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let cut = 100_000
        stub.respond = { r in
            guard r.url?.lastPathComponent == "model.safetensors" else { return nil }
            guard let range = r.header("Range") else {
                return StubReply(status: 200, body: weights.prefix(cut), fail: URLError(.timedOut))
            }
            #expect(range == "bytes=\(cut)-")
            return StubReply(status: 206, headers: ["Content-Range": "bytes \(cut)-\(weights.count - 1)/\(weights.count)"],
                             body: weights.suffix(from: cut))
        }
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        let seen = Seen()
        try await inst.install(spec) { seen.add($0, $1) }
        #expect(inst.isInstalled(spec))
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
        let w = stub.requests.filter { $0.url?.lastPathComponent == "model.safetensors" }
        #expect(w.map { $0.header("Range") } == [nil, "bytes=\(cut)-"])
        #expect(seen.all.contains { $0.0 == Int64(cut) } && zip(seen.all, seen.all.dropFirst()).allSatisfy { $0.0 <= $1.0 })
        #expect(!exists(root.appendingPathComponent("Tiny.partial")))
    }

    @Test func serverThatIgnoresRangeStartsTheFileAgain() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        stub.respond = { r in
            guard r.url?.lastPathComponent == "model.safetensors" else { return nil }
            if r.header("Range") == nil { return StubReply(status: 200, body: weights.prefix(50_000), fail: URLError(.networkConnectionLost)) }
            return StubReply(status: 200, body: weights)   // the whole file, not the rest
        }
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
    }

    @Test func wrongRangeStartsTheFileAgain() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let first = Seen()
        stub.respond = { r in
            guard r.url?.lastPathComponent == "model.safetensors" else { return nil }
            switch r.header("Range") {
            case nil where first.all.isEmpty:
                first.add(0, 0)
                return StubReply(status: 200, body: weights.prefix(50_000), fail: URLError(.timedOut))
            case "bytes=50000-": return StubReply(status: 206, headers: ["Content-Range": "bytes 10-99/300000"], body: weights[10..<100])
            default: return StubReply(status: 200, body: weights)
            }
        }
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        try await inst.install(spec) { _, _ in }
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
        #expect(stub.requests.filter { $0.url?.lastPathComponent == "model.safetensors" }.map { $0.header("Range") } == [nil, "bytes=50000-", nil])
    }

    @Test func fiveFailedTriesGiveUpAndKeepTheBytes() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        stub.respond = { r in
            guard r.url?.lastPathComponent == "model.safetensors" else { return nil }
            // 10,000 bytes more on each try, then the bytes stop
            let from = r.header("Range").flatMap { Int($0.dropFirst(6).dropLast()) } ?? 0
            return from == 0 ? StubReply(status: 200, body: weights.prefix(10_000), fail: URLError(.timedOut))
                : StubReply(status: 206, headers: ["Content-Range": "bytes \(from)-\(weights.count - 1)/\(weights.count)"],
                            body: weights[from..<(from + 10_000)], fail: URLError(.timedOut))
        }
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        let e = await installError { try await inst.install(spec) { _, _ in } }
        #expect(e == .gaveUp("model.safetensors", "The server did not answer in time.", tries: 5))
        #expect(e?.message == "model.safetensors: The server did not answer in time. Sanketa tried 5 times. Download again to go on from where it stopped.")
        #expect(stub.requests.count == 5 && !inst.isInstalled(spec))
        let part = root.appendingPathComponent("Tiny.partial/model.safetensors.partial")
        #expect(try Data(contentsOf: part) == weights.prefix(50_000))
        // the next install goes on from byte 50,000
        stub.respond = { r in
            guard r.url?.lastPathComponent == "model.safetensors" else { return nil }
            return StubReply(status: 206, headers: ["Content-Range": "bytes 50000-299999/300000"], body: weights.suffix(from: 50_000))
        }
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(stub.requests.last { $0.url?.lastPathComponent == "model.safetensors" }?.header("Range") == "bytes=50000-")
    }

    @Test func stalePartialFolderIsReplaced() async throws {
        let root = try modelTempDir()
        let partial = root.appendingPathComponent("Tiny.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: partial.appendingPathComponent("model.safetensors"))
        try rev.write(to: partial.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        try await inst.install(spec) { _, _ in }
        #expect(inst.isInstalled(spec))
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
        #expect(!exists(partial))
    }

    @Test func reinstallReplacesOldFolder() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
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
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
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
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        try await inst.install(spec) { _, _ in }
        let newer = ModelSpec(choice: spec.choice, repo: spec.repo, revision: String(repeating: "f", count: 40),
                              folder: spec.folder, files: spec.files)
        #expect(!inst.isInstalled(newer))
    }

    @Test func removeDeletesFolder() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        try await inst.install(spec) { _, _ in }
        try inst.remove(spec)
        #expect(!inst.isInstalled(spec))
        #expect(!exists(inst.directory(spec)))
        try inst.remove(spec)   // nothing there: no error
    }

    @Test func tooLittleSpaceDownloadsNothing() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let inst = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in 1000 }, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .noSpace(need: ModelInstaller.needed(spec.downloadSize), free: 1000))
        #expect(stub.requests.isEmpty && !inst.isInstalled(spec) && !exists(root.appendingPathComponent("Tiny.partial")))
    }

    @Test func secondInstallIsBusyAndCancelLeavesNothing() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        stub.hold = { p in if p.hasSuffix("/config.json") { entered.signal(); release.wait() } }
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
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
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        let u = try #require(URL(string: to))
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .redirectRefused("\(u.scheme!)://\(u.host!)"))
        #expect(!inst.isInstalled(spec))
        #expect(!exists(root.appendingPathComponent("Tiny")) && !exists(root.appendingPathComponent("Tiny.partial/model.safetensors")))
        #expect(stub.requests.allSatisfy { $0.url?.host == "huggingface.co" })
    }

    @Test func redirectToHFCDNIsFollowed() async throws {
        let root = try modelTempDir()
        var answers = good()
        answers[path("model.safetensors")] = [(302, Data("https://cas-bridge.xethub.hf.co/xet/w".utf8))]
        answers["/xet/w"] = [(200, weights)]
        let stub = Stub(data: answers)
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
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
        let inst = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in free }, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } }
                == .noSpace(need: spec.downloadSize + 256 << 20, free: free))
        #expect(stub.requests.isEmpty)
    }

    @Test func noSpaceForReinstallKeepsOldInstall() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        try await ModelInstaller(root: root, session: stub.session, backoff: fast).install(spec) { _, _ in }
        // the old folder stays until the new one is in place, so it frees nothing
        let inst = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in 100 << 20 }, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .noSpace(need: spec.downloadSize + 256 << 20, free: 100 << 20))
        #expect(inst.isInstalled(spec))
        #expect(try Data(contentsOf: inst.directory(spec).appendingPathComponent("model.safetensors")) == weights)
        #expect(stub.requests.count == 2)
    }

    @Test func lostConnectionIsNetworkError() async throws {
        let root = try modelTempDir()
        let stub = Stub(data: good())
        stub.failure = { $0.hasSuffix("/config.json") ? URLError(.networkConnectionLost) : nil }
        let inst = ModelInstaller(root: root, session: stub.session, backoff: fast)
        #expect(await installError { try await inst.install(spec) { _, _ in } } == .gaveUp("config.json", "The connection stopped.", tries: 5))
        #expect(!inst.isInstalled(spec) && !exists(root.appendingPathComponent("Tiny.partial/config.json")))
        // a cancel that did not come from us is not a CancellationError
        stub.failure = { _ in URLError(.cancelled) }
        #expect(await installError { try await ModelInstaller(root: try modelTempDir(), session: stub.session, backoff: fast)
            .install(spec) { _, _ in } } == .gaveUp("model.safetensors", "The download stopped.", tries: 5))
    }

    @Test func defaultSessionKeepsNothing() {
        let c = ModelInstaller.makeSession().configuration
        #expect(c.httpCookieStorage == nil && c.urlCredentialStorage == nil && c.urlCache == nil && !c.httpShouldSetCookies)
        #expect(c.timeoutIntervalForRequest == 60 && c.timeoutIntervalForResource == 7200)
    }

    @Test func catalogPinsMatchHFLayout() throws {
        let names = ["config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer.json",
                     "tokenizer_config.json", "chat_template.jinja"]
        let hex40 = try Regex("^[0-9a-f]{40}$"), hex64 = try Regex("^[0-9a-f]{64}$")
        for (c, gb) in [(MLXModelChoice.qwen4b, 3.06), (.qwen2b, 1.75), (.qwen4b6, 4.11)] {
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
        #expect(ModelCatalog.spec(.qwen4b6).repo == "mlx-community/Qwen3.5-4B-6bit")
        // Gemma has two weight shards and its own tokenizer files
        let g = ModelCatalog.spec(.gemma4e4b)
        #expect(g.choice == .gemma4e4b && g.repo == "mlx-community/unsloth-gemma-4-E4B-it-qat-oQ4")
        #expect(g.revision.wholeMatch(of: hex40) != nil && g.folder == String(g.repo.split(separator: "/").last!))
        #expect(Set(g.files.map(\.name)) == Set(names.filter { $0 != "model.safetensors" }
            + ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]))
        #expect(g.files.allSatisfy { $0.sha256.wholeMatch(of: hex64) != nil && $0.size > 0 })
        #expect(abs(Double(g.downloadSize) / 1e9 - 5.38) <= 0.05)
        let qwenTok = Set(ModelCatalog.qwen4b.files.filter { $0.name.hasPrefix("tokenizer") }.map(\.sha256))
        #expect(qwenTok.isDisjoint(with: g.files.map(\.sha256)))
    }

    @Test func defaultRootHonoursEnv() {
        #expect(ModelCatalog.defaultRoot(env: ["SANKETA_MODEL_DIR": "/tmp/x"]).path == "/tmp/x")
        #expect(ModelCatalog.defaultRoot(env: [:]).path.hasSuffix("/Library/Application Support/Sanketa/Models"))
    }

    /// Reads (never writes) the bench copies downloaded and checked on 2026-10-24, when they are there. The small
    /// files are hashed; the weights are checked by size only, so the test stays fast.
    @Test func catalogMatchesBenchCopies() throws {
        let bench = URL(fileURLWithPath: "/tmp/sanketa-bench/models")
        // each copy is checked only when it is there; the 2026-10-25 ones may be gone
        for (c, dir) in [(MLXModelChoice.qwen4b, "qwen35-4b-dl"), (.qwen2b, "qwen35-2b"),
                         (.gemma4e4b, "unsloth-gemma4-e4b-qat-oq4"), (.qwen4b6, "qwen35-4b-6bit")] {
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
