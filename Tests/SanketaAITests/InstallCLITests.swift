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
    func run(_ which: String?, force: Bool, mlxReady: Bool, memory: UInt64 = 36 << 30, installed: MLXModelChoice? = nil) async throws
        -> (status: Int32, out: [String], err: [String], stub: Stub, root: URL, chosen: [MLXModelChoice]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-installcli-\(UUID().uuidString)")
        let stub = Stub([:])   // every path answers 404
        let installer = ModelInstaller(root: root, session: stub.session, freeSpace: { _ in Int64.max })
        if let installed { try Self.fakeInstall(ModelCatalog.spec(installed), in: installer) }
        let out = Lines(), err = Lines()
        var chosen: [MLXModelChoice] = []
        let s = await InstallCLI.run(which: which, force: force, mlxReady: mlxReady, defaultChoice: .qwen2b, installer: installer,
                                     memory: memory, chosen: { chosen.append($0) }, out: out.add, err: err.add)
        return (s, out.lines, err.lines, stub, root, chosen)
    }

    /// An installed model as the installer leaves it: the `.verified` revision and each file at its size (sparse, so
    /// the test writes no gigabytes).
    static func fakeInstall(_ spec: ModelSpec, in installer: ModelInstaller) throws {
        let d = installer.directory(spec)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for f in spec.files {
            let u = d.appendingPathComponent(f.name)
            FileManager.default.createFile(atPath: u.path, contents: nil)
            let h = try FileHandle(forWritingTo: u)
            try h.truncate(atOffset: UInt64(f.size)); try h.close()
        }
        try spec.revision.write(to: d.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        try #require(installer.isInstalled(spec))
    }

    /// A Mac below 8 GB gets no model, not even with --force, and nothing is requested.
    @Test func smallMacRefusesEveryModelEvenWithForce() async throws {
        for which in [nil, "2b", "4b", "e4b", "4b-6bit"] as [String?] {
            for force in [false, true] {
                let r = try await run(which, force: force, mlxReady: true, memory: 4 << 30)
                #expect(r.status == 2 && r.stub.requests.isEmpty && r.chosen.isEmpty, "\(String(describing: which)) force \(force)")
                #expect(r.err == ["This Mac does not have enough memory for an on-device model. Search uses plain search. This Mac has 4 GB. The smallest model needs 8 GB."])
            }
        }
    }

    /// Each RAM size gets the models that fit without --force.
    @Test func memoryDecidesWhichModelsNeedForce() async throws {
        for (gb, fits) in [(8, ["2b", "4b", "4b-6bit"]), (16, ["2b", "4b", "4b-6bit", "e4b"]), (32, ["2b", "4b", "4b-6bit", "e4b"])] as [(UInt64, [String])] {
            for which in ["2b", "4b", "4b-6bit", "e4b"] {
                let r = try await run(which, force: false, mlxReady: true, memory: gb << 30)
                #expect((r.stub.requests.count == 1) == fits.contains(which), "\(gb) GB \(which): \(r.err)")
            }
        }
    }

    /// A model that is installed becomes the chosen one, so `on_device` goes on.
    @Test func installedModelIsChosen() async throws {
        let r = try await run("2b", force: false, mlxReady: true, memory: 8 << 30, installed: .qwen2b)
        #expect(r.status == 0 && r.chosen == [.qwen2b] && r.stub.requests.isEmpty)
        let failed = try await run("4b", force: false, mlxReady: true)
        #expect(failed.status == 1 && failed.chosen.isEmpty, "a failed download chooses nothing")
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
