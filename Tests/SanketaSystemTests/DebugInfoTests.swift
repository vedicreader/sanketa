import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// Copy Debug Info and `--dump-context`: the facts that help a bug report, and nothing from the user's files.
@Suite struct DebugInfoTests {
    static let home = "/Users/tester"

    func context() throws -> (Context, PackLibrary) {
        var lib = PackLibrary.load(bundled: BundledPacksSystemTests.packs, user: nil)
        lib.errors = [PackLoadError(file: Self.home + "/.config/sanketa/packs/duckdb.toml", message: "key 2 has no action")]
        let r = LayerResolver(library: lib, tmux: NoTmux(), remote: nil)
        let layers = [r.layer("htop", argv: ["htop"]), Layer(kind: .remote, name: "gpubox.lab.example", host: "gpubox.lab.example"), r.layer("python3.13", argv: ["python3", Self.home + "/.local/bin/ramabana"]),
                      r.layer("fish", argv: ["-fish"]), Layer(kind: .terminal, name: "Kaku", packID: "app:fun.tw93.kaku", reason: "menu keys")]
        let packs = try ["htop", "ramabana", "fish"].map { try #require(lib.packs[$0]) }
        return (Context(appName: "Kaku", bundleID: "fun.tw93.kaku", layers: layers, packs: packs, axTrusted: false), lib)
    }

    @Test func contextLinesGiveTheReasonForEachPack() throws {
        let (c, _) = try context()
        let lines = DebugInfo.context(c, title: "htop — orgs", showTitle: true)
        #expect(lines.prefix(2) == ["app: Kaku (fun.tw93.kaku) axTrusted=false", "title: \"htop — orgs\" scope=- context=-"])
        #expect(lines.contains("  program htop pack=htop via process htop"))
        #expect(lines.contains("  program ramabana pack=ramabana via match \"bin/ramabana\""))
        #expect(lines.contains("  shell fish pack=fish via process fish"))
        #expect(lines.contains { $0.hasPrefix("  htop keys=") })
        #expect(lines.contains("  remote gpubox.lab.example pack=- host=gpubox.lab.example"))   // the CLI is local: hosts show
        #expect(DebugInfo.stack(c) == "htop › gpubox.lab.example › ramabana › fish › Kaku")
    }

    @Test func reportHasNoFileContentsOrHomePaths() throws {
        let (c, lib) = try context()
        let r = DebugInfo.report(version: "1.2.3", context: c, library: lib, configPath: Self.home + "/.config/sanketa/config.toml",
                                 configError: "line 1: hotkey must be a string", home: Self.home)
        #expect(r.hasPrefix("Sanketa 1.2.3 on macOS "))
        #expect(r.contains("config: ~/.config/sanketa/config.toml (did not load: line 1: hotkey must be a string)"))
        #expect(r.contains("pack files that did not load: 1") && r.contains("axTrusted=false"))
        #expect(!r.contains(Self.home) && !r.contains("title:") && !r.contains("duckdb"))
        #expect(r.contains("  remote remote host pack=- host=remote host") && !r.contains("gpubox"))
        // pack contents (actions, snippets) stay out
        for p in c.packs { for k in p.keys { #expect(!r.contains(k.action), "\(k.action)") } }
    }
}

struct NoTmux: TmuxQuerying {
    func clients(tmux: String) -> [TmuxClient] { [] }
    func liveKeys(tmux: String) -> (prefix: String?, keys: [KeyEntry]) { (nil, []) }
}
