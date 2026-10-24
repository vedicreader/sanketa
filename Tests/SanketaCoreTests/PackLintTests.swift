import Foundation
import Testing
@testable import SanketaCore

@Suite struct PackLintTests {
    func lint(_ toml: String) -> [String] { PackLint.lint(Data(toml.utf8)).map(\.description) }
    func errors(_ toml: String) -> [String] { PackLint.lint(Data(toml.utf8)).filter { $0.level == .error }.map(\.message) }

    /// The bundle stays clean: no errors and no warnings in any bundled pack.
    @Test func bundledPacksAreClean() {
        let r = PackLint.run([bundledPacksDir.path])
        #expect(r.status == 0)
        #expect(r.lines == ["\(bundledFiles().count) files: 0 errors, 0 warnings"], "\(r.lines.joined(separator: "\n"))")
    }

    @Test func docsExamplesHaveNoErrors() throws {
        let md = try String(contentsOf: repoRoot.appendingPathComponent("docs/packs.md"), encoding: .utf8)
        let blocks = md.components(separatedBy: "```toml\n").dropFirst().map { $0.components(separatedBy: "\n```")[0] }
        try #require(!blocks.isEmpty)
        for b in blocks { #expect(errors(b).isEmpty, "\(b.prefix(40)): \(errors(b))") }
    }

    @Test func typoInFieldNameIsAnError() {
        let e = errors("id = \"duckdb\"\nname = \"DuckDB\"\nproccesses = [\"duckdb\"]\n\n[[keys]]\nkeys = \"⌃D\"\nacton = \"Quit\"\n")
        #expect(e.contains("the pack: unknown field proccesses. Did you mean processes?"))
        #expect(e.contains("key 1: unknown field acton. Did you mean action?"))
        #expect(e.contains("key 1 has no action"))
    }

    @Test func missingRequiredFieldsAndWrongTypes() {
        let e = errors("name = \"x\"\nprocesses = \"x\"\n\n[[keys]]\nkeys = \"a\"\naction = \"A\"\n\n[[keys]]\nkeys = \"b\"\n\n[[tips]]\ntitle = \"T\"\n\n[[contexts]]\nscopes = [\"s\"]\n")
        #expect(e.contains("the pack has no id"))
        #expect(e.contains("the pack: processes must be a list of strings"))
        #expect(e.contains("key 2 has no action"))
        #expect(e.contains("tip 1 has no snippet"))
        #expect(e.contains("context 1 has no name"))
        #expect(errors("id = \"x\"\nname = \"x\"\nprocesses = [\"x\"]\nmode = \"merge\"\n") == ["mode must be extend or replace, not merge"])
    }

    @Test func keyStyleOutsideTmuxPacks() {
        let pack = { (prefix: String, keys: [String]) in
            "id = \"y\"\nname = \"y\"\nprocesses = [\"y\"]\n\(prefix)\n" + keys.enumerated().map { "[[keys]]\nkeys = \"\($1)\"\naction = \"A\($0)\"\n" }.joined(separator: "\n")
        }
        #expect(errors(pack("", ["Enter", "C-d", "Space", "⌘⇧P", "Esc", "⇥", "PgUp / PgDn", "ctrl+r"])) == [
            "key 1 (Enter): write ↩", "key 2 (C-d): write ⌃D", "key 3 (Space): write space", "key 4 (⌘⇧P): write ⇧⌘P",
            "key 5 (Esc): write esc", "key 6 (⇥): write tab", "key 7 (PgUp / PgDn): write pgup / pgdn", "key 8 (ctrl+r): write ⌃R",
        ])
        // already in the docs style, and typed text, stay quiet
        #expect(errors(pack("", ["↩", "⌃D", "space", "⇧⌘P", "esc", "⇧tab", "g g", "/model NAME", ":wq", "n: REASON ↩", "⌃P / ⌃N", "F5"])).isEmpty)
        // tmux notation is right in a pack with a prefix
        #expect(errors(pack("prefix = \"C-b\"", ["prefix C-o", "prefix M-Up"])).isEmpty)
    }

    @Test func duplicateKeysInAGroup() {
        let toml = "id = \"y\"\nname = \"y\"\nprocesses = [\"y\"]\n\n[[keys]]\nkeys = \"j\"\naction = \"Down\"\ngroup = \"Move\"\n\n[[keys]]\nkeys = \"j\"\naction = \"Next\"\ngroup = \"Move\"\n\n[[keys]]\nkeys = \"j\"\naction = \"Other\"\ngroup = \"Files\"\n"
        #expect(errors(toml) == ["key 2 (j): same keys as key 1 in group Move"])
    }

    @Test func badRegexes() {
        let base = "id = \"y\"\nname = \"y\"\napps = [\"a.b\"]\n"
        #expect(errors(base + "title_scope = '([a-z'\n") == ["title_scope is not a valid regex"])
        #expect(errors(base + "title_scope = ' · [a-z]+$'\n") == ["title_scope has no group. Put ( ) around the scope token."])
        #expect(errors(base + "titles = ['^ok$', '(?<bad']\n") == ["titles 2 is not a valid regex"])
        #expect(errors(base + "title_scope = ' · ([a-z]+)$'\n").isEmpty)
    }

    @Test func warningsDoNotFail() throws {
        let toml = "id = \"y\"\nname = \"y\"\nmatch = [\"vi\"]\n\n[[keys]]\nkeys = \"a\"\naction = \"One two three four five six seven\"\n\n[[tips]]\ntitle = \"T\"\nsnippet = \"s\"\n\n[[tips]]\ntitle = \"T\"\nsnippet = \"t\"\n"
        #expect(lint(toml) == ["warning: key 1 (a): the action has 7 words. Use 6 or fewer.",
                               "warning: tip 2: same title as tip 1, so it replaces that tip",
                               "warning: match 1 (vi) is short and can find other programs"])
        let d = try tempDir(["y.toml": toml])
        #expect(PackLint.run([d.path]).status == 0)
    }

    /// The loader and the footer use the same short lines as the lint.
    @Test func loadErrorsAreReadable() throws {
        let d = try tempDir(["duckdb.toml": "id = \"duckdb\"\nname = \"DuckDB\"\n\n[[keys]]\nkeys = \"⌃D\"\naction = \"Quit\"\n\n[[keys]]\nkeys = \".tables\"\n",
                             "syntax.toml": "id = \"s\"\nname = \"S\nx = [[ no\n"])
        let lib = PackLibrary.load(bundled: d, user: nil)
        let byFile = Dictionary(uniqueKeysWithValues: lib.errors.map { (($0.file as NSString).lastPathComponent, $0.message) })
        #expect(byFile["duckdb.toml"] == "key 2 has no action")
        let syntax = try #require(byFile["syntax.toml"])
        #expect(syntax.hasPrefix("line ") && !syntax.contains("TOMLError") && !syntax.contains("DecodingError"), "\(syntax)")
        let r = PackLint.run([d.path])
        #expect(r.status == 1 && r.lines.contains("duckdb.toml: key 2 has no action"))
        #expect(PackLint.run([d.appendingPathComponent("none.toml").path]).status == 2)
    }

    @Test func styleFixKeepsSeparators() {
        #expect(PackLint.styleFix("F10 / q / ⎋") == "F10 / q / esc")
        #expect(PackLint.styleFix("⌃X ⌃E") == nil)
    }
}
