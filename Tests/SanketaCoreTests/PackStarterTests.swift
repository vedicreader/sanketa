import Foundation
import Testing
@testable import SanketaCore

/// "Make a pack for duckdb" writes a first pack that loads, lints clean and shows for the program.
@Suite struct PackStarterTests {
    /// The layer the resolver makes for a process when no pack matches it, as the panel gets it.
    func layer(_ p: ProcInfo) -> Layer {
        LayerResolver(library: PackLibrary(), tmux: FakeTmux(), remote: nil).layer(p.name, argv: p.argv)
    }

    func proc(_ name: String, _ argv: [String]) -> ProcInfo {
        ProcInfo(pid: 900, ppid: 1, pgid: 900, tty: "ttys009", tpgid: 900, name: name, argv: argv, start: 0, path: nil)
    }

    /// The generated pack, loaded by the real loader, picks the same process again.
    func activates(_ p: ProcInfo) throws -> (Pack, String)? {
        let d = try tempDir().appendingPathComponent("packs")
        let f = try PackStarter.make(for: layer(p), in: d)
        #expect(PackLint.lint(file: f).isEmpty, "\(PackLint.lint(file: f))")
        let lib = PackLibrary.load(bundled: d, user: nil)
        #expect(lib.errors.isEmpty)
        return lib.pick(process: p.name, argv: p.argv).map { ($0.pack, $0.reason) }
    }

    @Test func programPackActivates() throws {
        let p = proc("duckdb", ["duckdb", "x.db"])
        let (pack, reason) = try #require(try activates(p))
        #expect(pack.id == "duckdb" && pack.processes == ["duckdb"] && reason == "process duckdb")
    }

    /// A Python script runs as python3.x, so a `processes` entry would never match; the pack uses `match`.
    @Test func interpreterScriptPackActivates() throws {
        let p = proc("python3.13", ["/opt/homebrew/bin/python3", "/Users/x/.local/bin/toolbox", "--resume"])
        let l = layer(p)
        #expect(l.name == "toolbox" && l.packID == nil)
        let (pack, reason) = try #require(try activates(p))
        #expect(pack.id == "toolbox" && pack.match == ["bin/toolbox"] && pack.processes.isEmpty)
        #expect(reason == "match \"bin/toolbox\"")
        // a script named cli.py shows as its folder; the match keeps the folder too
        let cli = proc("python3", ["python3", "/Users/x/code/foo/cli.py"])
        #expect(try activates(cli)?.0.match == ["foo/cli.py"])
    }

    /// Claude Code's process is a version number; argv[0] is the name, and `processes` matches it.
    @Test func argvZeroNamePackActivates() throws {
        let (pack, reason) = try #require(try activates(proc("2.1.304", ["claude", "-c"])))
        #expect(pack.id == "claude" && reason == "argv[0] claude")
    }

    @Test func keyExampleIsValidOnceUncommented() throws {
        let text = PackStarter.text(for: layer(proc("duckdb", ["duckdb"])))
        let open = text.replacingOccurrences(of: "# [[keys]]", with: "[[keys]]").replacingOccurrences(of: "# keys", with: "keys")
            .replacingOccurrences(of: "# action", with: "action").replacingOccurrences(of: "# group", with: "group")
        #expect(try PackLibrary.decode(Data(open.utf8)).keys.map(\.keys) == ["⌃D"])
        #expect(PackLint.lint(Data(open.utf8)).isEmpty)
    }

    @Test func neverOverwritesTheUsersFile() throws {
        let d = try tempDir()
        let l = layer(proc("duckdb", ["duckdb"]))
        let f = try PackStarter.make(for: l, in: d)
        try "id = \"duckdb\"\nname = \"Mine\"\n".write(to: f, atomically: true, encoding: .utf8)
        #expect(try PackStarter.make(for: l, in: d) == f)
        #expect(try String(contentsOf: f, encoding: .utf8).contains("Mine"))
    }

    @Test func idIsSafeForAFileName() throws {
        #expect(PackStarter.id("DuckDB CLI") == "duckdb-cli")
        #expect(!PackStarter.id("../x y").contains("/"))
        #expect(PackStarter.id("python3.13") == "python3.13" && PackStarter.id("///") == "pack")
        let f = try PackStarter.make(for: Layer(kind: .program, name: "my \"tool\""), in: try tempDir())
        #expect(try PackLibrary.decode(Data(contentsOf: f)).processes == ["my \"tool\""])
    }
}
