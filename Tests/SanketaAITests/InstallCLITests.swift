import Testing
import Foundation
@testable import SanketaAI
import SanketaCore

/// Lines that `InstallCLI.run` prints.
private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var lines: [String] { lock.withLock { all } }
}

@Suite struct InstallCLITests {
    func run(_ which: String?, force: Bool, mlxReady: Bool, memory: UInt64 = 36 << 30) async throws -> (status: Int32, out: [String], err: [String], stub: Stub, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-installcli-\(UUID().uuidString)")
        let stub = Stub([:])   // every path answers 404
        let installer = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in Int64.max })
        let out = Lines(), err = Lines()
        let s = await InstallCLI.run(which: which, force: force, mlxReady: mlxReady, defaultChoice: .qwen2b, installer: installer,
                                     memory: memory, out: out.add, err: err.add)
        return (s, out.lines, err.lines, stub, root)
    }

    @Test func refusesWithoutForceWhileBuildCannotRunModel() async throws {
        for which in [nil, "2b", "4b", "e4b"] as [String?] {
            let r = try await run(which, force: false, mlxReady: false)
            #expect(r.status == 2)
            #expect(r.err == ["This build cannot run on-device models yet. Use --force to download anyway."])
            #expect(r.out.isEmpty && r.stub.requests.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: r.root.path))
        }
    }

    @Test func unknownSizeIsUsageError() async throws {
        let r = try await run("9b", force: true, mlxReady: true)
        #expect(r.status == 2 && r.err == [InstallCLI.usage] && r.stub.requests.isEmpty)
    }

    @Test func forceDownloadsFromPinnedURL() async throws {
        // the stub answers 404, so the download fails after its first request, and nothing is installed
        let r = try await run("2b", force: true, mlxReady: false)
        #expect(r.status == 1)
        #expect(r.out.first == "downloading mlx-community/Qwen3.5-2B-MLX-4bit (1.7 GB)")
        #expect(r.stub.requests.first?.url?.host == "huggingface.co")
        #expect(r.err.first?.hasPrefix("cannot install Qwen3.5-2B-MLX-4bit:") == true)
        #expect(!FileManager.default.fileExists(atPath: r.root.appendingPathComponent("Qwen3.5-2B-MLX-4bit").path))
    }

    @Test func e4bIsGemma() async throws {
        let r = try await run("e4b", force: false, mlxReady: true)
        #expect(r.status == 1)
        #expect(r.out.first == "downloading mlx-community/unsloth-gemma-4-E4B-it-qat-oQ4 (5.4 GB)")
        #expect(r.stub.requests.first?.url?.path.hasPrefix("/mlx-community/unsloth-gemma-4-E4B-it-qat-oQ4/resolve/eaa5413e") == true)
    }

    @Test func gemmaOnASmallMacNeedsForce() async throws {
        let r = try await run("e4b", force: false, mlxReady: true, memory: 8 << 30)
        #expect(r.status == 2 && r.stub.requests.isEmpty)
        #expect(r.err == ["Gemma 4 E4B needs 16 GB of memory. This Mac has 8 GB. Use --force to download it anyway."])
        let forced = try await run("e4b", force: true, mlxReady: true, memory: 8 << 30)
        #expect(forced.stub.requests.first?.url?.host == "huggingface.co")
        #expect(try await run("4b", force: false, mlxReady: true, memory: 8 << 30).stub.requests.count == 1)
    }

    @Test func progressGivesEachStepOnce() {
        let p = ProgressSteps()
        let got = [0, 1, 4, 5, 9, 10, 52, 53, 100].compactMap { p.next(done: Int64($0), total: 100) }
        #expect(got == [0, 5, 10, 50, 100])
    }
}
