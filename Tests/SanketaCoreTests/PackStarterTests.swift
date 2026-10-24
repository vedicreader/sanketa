import Foundation
import Testing
@testable import SanketaCore

/// "Make a pack for duckdb" writes a first pack that loads, lints clean and shows for the program.
@Suite struct PackStarterTests {
    @Test func writesAPackThatLoadsAndLintsClean() throws {
        let d = try tempDir().appendingPathComponent("packs")
        let f = try PackStarter.make(name: "duckdb", in: d)
        #expect(f.lastPathComponent == "duckdb.toml")
        #expect(PackLint.lint(file: f).isEmpty, "\(PackLint.lint(file: f))")
        let lib = PackLibrary.load(bundled: d, user: nil)
        #expect(lib.errors.isEmpty && lib.pack(process: "duckdb", argv: ["duckdb"])?.id == "duckdb")
        // removing the # signs gives a valid key
        let text = try String(contentsOf: f, encoding: .utf8)
        let open = text.replacingOccurrences(of: "# [[keys]]", with: "[[keys]]").replacingOccurrences(of: "# keys", with: "keys")
            .replacingOccurrences(of: "# action", with: "action").replacingOccurrences(of: "# group", with: "group")
        #expect(try PackLibrary.decode(Data(open.utf8)).keys.map(\.keys) == ["⌃D"])
        #expect(PackLint.lint(Data(open.utf8)).isEmpty)
    }

    @Test func neverOverwritesTheUsersFile() throws {
        let d = try tempDir()
        let f = try PackStarter.make(name: "duckdb", in: d)
        try "id = \"duckdb\"\nname = \"Mine\"\n".write(to: f, atomically: true, encoding: .utf8)
        #expect(try PackStarter.make(name: "duckdb", in: d) == f)
        #expect(try String(contentsOf: f, encoding: .utf8).contains("Mine"))
    }

    @Test func idIsSafeForAFileName() throws {
        #expect(PackStarter.id("DuckDB CLI") == "duckdb-cli")
        #expect(!PackStarter.id("../x y").contains("/"))
        #expect(PackStarter.id("python3.13") == "python3.13" && PackStarter.id("///") == "pack")
        let f = try PackStarter.make(name: "my \"tool\"", in: try tempDir())
        #expect(try PackLibrary.decode(Data(contentsOf: f)).processes == ["my \"tool\""])
    }
}
