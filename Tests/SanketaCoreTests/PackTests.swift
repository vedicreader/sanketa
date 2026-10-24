import Foundation
import Testing
@testable import SanketaCore

func fixtures(_ sub: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/packs/\(sub)")
}

func tempDir(_ files: [String: String]) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (n, c) in files { try c.write(to: d.appendingPathComponent(n), atomically: true, encoding: .utf8) }
    return d
}

@Suite struct PackTests {
    @Test func decodeMinimalPack() throws {
        let p = try PackLibrary.decode(Data("id = \"x\"\nname = \"X\"\n".utf8))
        #expect(p.id == "x" && p.name == "X")
        #expect(p.processes.isEmpty && p.match.isEmpty && p.apps.isEmpty)
        #expect(p.keys.isEmpty && p.tips.isEmpty && p.prefix == nil && p.mode == .extend)
    }

    @Test func decodeFullPack() throws {
        let data = try Data(contentsOf: fixtures("bundled").appendingPathComponent("tmux.toml"))
        let p = try PackLibrary.decode(data)
        #expect(p.keys[0].keys == "prefix %" && p.keys[0].group == "Panes" && p.keys[0].command == nil)
        #expect(p.prefix == "C-b" && p.processes == ["tmux"])
        let fish = try PackLibrary.decode(Data(contentsOf: fixtures("bundled").appendingPathComponent("fish.toml")))
        #expect(fish.tips[0].tags == ["loops", "files"])
    }

    @Test func decodeRejectsMissingID() {
        #expect(throws: (any Error).self) { try PackLibrary.decode(Data("name = \"X\"\n".utf8)) }
    }

    @Test func mergeExtendReplacesSameKeysAndAppends() throws {
        let lib = PackLibrary.load(bundled: fixtures("bundled"), user: fixtures("user"))
        let t = try #require(lib.packs["tmux"])
        #expect(t.name == "tmux (mine)" && t.prefix == "C-b")
        #expect(t.keys.map(\.keys) == ["prefix %", "prefix c", "prefix z"])
        #expect(t.keys[0].action == "Vertical split (my wording)")
        #expect(t.tips.count == 1 && t.tips[0].snippet == "tmux detach -a")
        #expect(t.processes == ["tmux", "tmux-next"] && t.apps == ["com.example.Mux"])
    }

    @Test func mergeReplaceDropsBase() throws {
        let lib = PackLibrary.load(bundled: fixtures("bundled"), user: fixtures("user"))
        let f = try #require(lib.packs["fish"])
        #expect(f.name == "fish replaced" && f.keys.map(\.keys) == ["ctrl-r"])
        #expect(f.tips.isEmpty && f.processes.isEmpty)
    }

    @Test func lookupArgvBeforeProcess() throws {
        let d = try tempDir([
            "python.toml": "id = \"python\"\nname = \"Python\"\nprocesses = [\"python3\"]\n",
            "rama.toml": "id = \"ramabana\"\nname = \"ramabana\"\nmatch = [\"ramabana\"]\n",
        ])
        let lib = PackLibrary.load(bundled: d, user: nil)
        #expect(lib.pack(process: "python3", argv: ["python3", "/Users/x/.local/bin/ramabana"])?.id == "ramabana")
        #expect(lib.pack(process: "python3", argv: ["python3"])?.id == "python")
        #expect(lib.pack(process: "ruby", argv: ["ruby"]) == nil)
    }

    @Test func lookupByBundleID() throws {
        let lib = PackLibrary.load(bundled: fixtures("bundled"), user: fixtures("user"))
        #expect(lib.pack(bundleID: "com.example.Mux")?.id == "tmux")
        #expect(lib.pack(bundleID: "com.example.None") == nil)
    }

    @Test func loadSkipsBadPackAndReportsError() throws {
        let lib = PackLibrary.load(bundled: fixtures("bundled"), user: fixtures("user"))
        #expect(lib.packs["good"] != nil && lib.packs["bad"] == nil)
        #expect(lib.errors.count == 1)
        #expect(lib.errors[0].file.hasSuffix("zbad.toml"))
        #expect(!lib.errors[0].message.isEmpty)
    }
}
