import Foundation
import Testing
@testable import SanketaCore

/// The real bundled leela.toml overlaid with keys.json files written to temp dirs (never the user's own file).
@Suite struct LeelaKeymapTests {
    let bundled = PackLibrary.load(bundled: bundledPacksDir, user: nil)

    func load(_ json: String?, hyperLabel: String = "Caps") throws -> PackLibrary {
        var lib = bundled
        let url = try json.map { try tempDir(["keys.json": $0]).appendingPathComponent("keys.json") }
        LeelaKeymap.apply(to: &lib, keysJSON: url, hyperLabel: hyperLabel)
        return lib
    }

    func keys(_ lib: PackLibrary, _ id: String) -> String? {
        lib.packs["leela"]?.keys.first { $0.command == id }?.keys
    }

    func shown(_ s: String?) -> String? { s.map { KeyNotation.display($0).replacingOccurrences(of: "\u{a0}", with: " ") } }

    @Test func bundledPackIsLeelaDefaultsWithActionIDs() throws {
        let p = try #require(bundled.packs["leela"])
        let ids = p.keys.compactMap(\.command)
        #expect(ids.count >= 230 && Set(ids).count == ids.count)
        #expect(p.keys.first { $0.command == "toggle_left" }?.keys == "alt+shift+b hyper+left")
        #expect(p.keys.first { $0.command == "help" }?.keys == "mod+shift+/")
        #expect(!p.tips.contains { $0.explain.contains("Your keys.json") || $0.title.contains("Your ") })
    }

    @Test func noFileGivesDefaults() throws {
        let lib = try load(nil)
        #expect(shown(keys(lib, "toggle_left")) == "⌥⇧B  /  Caps ←")
        #expect(shown(keys(lib, "help")) == "⇧⌘/")
        #expect(shown(keys(lib, "new_dir")) == "⇧N")
        #expect(shown(keys(lib, "cell_render")) == "esc")
        #expect(shown(keys(lib, "run_below")) == "Caps pgdn")
        #expect(keys(lib, "quit") == nil)                                  // unbound by default: hidden
    }

    @Test func overrideReplacesDefault() throws {
        let lib = try load(#"{"_defaults": {"ask_ai": "hyper+a", "next_tab": "alt+]"}, "keys": {"ask_ai": "alt+q", "next_tab": "alt+ß", "prev_tab": "alt+å"}}"#)
        #expect(shown(keys(lib, "ask_ai")) == "⌥Q")
        #expect(shown(keys(lib, "next_tab")) == "⌥ß")
        #expect(shown(keys(lib, "prev_tab")) == "⌥å")
        #expect(shown(keys(lib, "save")) == "⌘S")                         // untouched action keeps its default
    }

    @Test func emptyOverrideHidesEntry() throws {
        let lib = try load(#"{"keys": {"help": ""}}"#)
        #expect(keys(lib, "help") == nil)
        #expect(!(lib.packs["leela"]?.keys.contains { $0.action == "Keys help" } ?? true))
    }

    @Test func overrideCanBindAnUnboundAction() throws {
        #expect(shown(keys(try load(#"{"keys": {"quit": "mod+q"}}"#), "quit")) == "⌘Q")
    }

    @Test func severalChordsGiveSeveralKeys() throws {
        let lib = try load(#"{"keys": {"toggle_left": "hyper+z alt+shift+b", "save": "mod+s ctrl+s f2"}}"#)
        #expect(shown(keys(lib, "toggle_left")) == "Caps Z  /  ⌥⇧B")
        #expect(shown(keys(lib, "save")) == "⌘S  /  ⌃S  /  F2")
    }

    @Test func hyperShowsAsCapsPlusKey() throws {
        #expect(shown(LeelaKeymap.render("hyper+e")) == "Caps E")
        let lib = try load(#"{"keys": {"edit_keys": "hyper+e"}}"#)
        #expect(shown(keys(lib, "edit_keys")) == "Caps E")
        #expect(shown(keys(try load(#"{"keys": {"edit_keys": "hyper+e"}}"#, hyperLabel: "Hyper"), "edit_keys")) == "Hyper E")
    }

    @Test func defaultsSectionUsedWhenNoOverride() throws {
        #expect(shown(keys(try load(#"{"_defaults": {"git_blame": "hyper+y"}, "keys": {}}"#), "git_blame")) == "Caps Y")
    }

    @Test func legacyFlatFileAndBrokenFile() throws {
        #expect(shown(keys(try load(#"{"save": "ctrl+s"}"#), "save")) == "⌃S")
        let broken = try load("{not json")
        #expect(shown(keys(broken, "save")) == "⌘S")
        #expect(broken.errors.contains { $0.file.hasSuffix("keys.json") })
    }

    /// Fixed keys (no action id) stay as written; no Leela chord syntax is left after the overlay.
    @Test func fixedEntriesKeptAndNoChordSyntaxLeft() throws {
        let p = try #require(try load(#"{"keys": {"save": "mod+s ctrl+alt+s"}}"#).packs["leela"])
        #expect(p.keys.contains { $0.command == nil && $0.action == "Approve the tool call" && $0.keys == "↩" })
        let raw = try Regex(#"(?i:mod|hyper|ctrl|alt|shift)\+"#)
        for k in p.keys { #expect(k.keys.firstMatch(of: raw) == nil, "\(k.keys)") }
    }
}
