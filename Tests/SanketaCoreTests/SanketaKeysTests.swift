import Foundation
import Testing
@testable import SanketaCore

/// Sanketa's own search key: its chord grammar, the writer of `hotkey` in config.toml, and the suggestions.
@Suite struct SanketaKeysTests {
    let toml = """
    # my settings
    hotkey   = "ctrl+opt+k"   # search
    translucency = "low"

    [coach]
    enabled = true
    """

    @Test func theHotkeyGrammarReadsAndWritesChords() {
        #expect(Chord.hotkey("ctrl+opt+k") == Chord(mods: [.ctrl, .opt], key: "k"))
        #expect(Chord.hotkey("Alt+Shift+Space") == Chord(mods: [.opt, .shift], key: "space"))
        #expect(Chord.hotkey("ctrl+opt+f5") == Chord(mods: [.ctrl, .opt], key: "f5"))
        #expect(Chord.hotkey("ctrl+opt+left") == nil)   // Sanketa cannot register it
        #expect(Chord.hotkey("ctrl+opt") == nil)
        #expect(Chord(mods: [.shift, .opt], key: "space").hotkeyText == "opt+shift+space")
        #expect(Chord(mods: Set(Modifier.allCases), key: "s").hotkeyText == "ctrl+opt+shift+cmd+s")
        #expect(Chord(mods: [.ctrl], key: "left").hotkeyText == nil)
        #expect(Chord(mods: [], key: "s").hotkeyText == nil)   // a key with no modifier is no hotkey
        for s in ["opt+shift+space", "ctrl+opt+s", "shift+cmd+f12", "ctrl+opt+."] {
            #expect(Chord.hotkey(s)?.hotkeyText == s)
            #expect(Hotkey.parse(s) != nil)
        }
    }

    @Test func theWriterChangesOnlyTheValue() throws {
        let out = try SanketaConfigWriter.change(toml, to: Chord(mods: [.ctrl, .opt], key: "s"))
        #expect(out == toml.replacingOccurrences(of: "\"ctrl+opt+k\"", with: "\"ctrl+opt+s\""))
    }

    @Test func theWriterKeepsCRLFAndOtherBytes() throws {
        let t = "a = 1\r\nhotkey='ctrl+opt+k'\r\n# \u{e9}\r\n"
        let out = try SanketaConfigWriter.change(t, to: Chord(mods: [.opt, .shift], key: "space"))
        #expect(out == "a = 1\r\nhotkey=\"opt+shift+space\"\r\n# \u{e9}\r\n")
    }

    @Test func theWriterAddsTheLineBeforeTheFirstTable() throws {
        let t = "# hotkey = \"ctrl+opt+k\"\ntranslucency = \"low\"\n\n[coach]\nhotkey = \"x\"\n"
        let out = try SanketaConfigWriter.change(t, to: Chord(mods: [.ctrl, .opt], key: "s"))
        #expect(out == "# hotkey = \"ctrl+opt+k\"\ntranslucency = \"low\"\n\nhotkey = \"ctrl+opt+s\"\n[coach]\nhotkey = \"x\"\n")
        #expect(try SanketaConfigWriter.change("", to: Chord(mods: [.ctrl, .opt], key: "s")) == "hotkey = \"ctrl+opt+s\"\n")
        #expect(try SanketaConfigWriter.change("a = 1", to: Chord(mods: [.ctrl, .opt], key: "s")) == "a = 1\nhotkey = \"ctrl+opt+s\"\n")
    }

    @Test func theWriterRefusesABadChord() {
        let left = Chord(mods: [.ctrl, .opt], key: "left")
        #expect(throws: KeyWriteError.notHotkey("⌃⌥←")) { try SanketaConfigWriter.change(toml, to: left) }
        #expect(throws: KeyWriteError.sameKey) { try SanketaConfigWriter.change(toml, to: Chord(mods: [.ctrl, .opt], key: "k")) }
        #expect(throws: KeyWriteError.notTOML) { try SanketaConfigWriter.change("hotkey = = x\n", to: Chord(mods: [.ctrl, .opt], key: "s")) }
        #expect(KeyWriteError.notHotkey("⌃⌥←").errorDescription == "Sanketa cannot use ⌃⌥← as a hotkey. Use one or more modifier keys with a letter, a digit, Space, F1 to F12, or / . ,. Sanketa did not change the file.")
    }

    @Test func undoPutsTheOldFileBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("config.toml")
        try toml.write(to: f, atomically: true, encoding: .utf8)
        let c = KeyChange(file: f, before: toml, after: try SanketaConfigWriter.change(toml, to: Chord(mods: [.opt, .shift], key: "space")), reload: nil)
        let store = KeyChangeStore(runner: FakeRunner(check: "", query: ""))
        #expect(try store.apply(c))
        #expect(Config.load(f).config.hotkey == "opt+shift+space")
        #expect(try store.undo(c))
        #expect(try Data(contentsOf: f) == Data(toml.utf8))
    }

    @Test func hotkeySuggestionsPutTheLeftHandFirstAndSkipUsedChords() {
        let now = Chord(mods: [.ctrl, .opt], key: "k")
        let s = KeySuggest.suggestHotkey(action: "Search", used: [now], system: KeySuggest.systemChords, hyperLabel: "Caps")
        #expect(s.map { $0.chord.display() } == ["⌥⇧space", "⌃⌥S", "⌥⇧A", "⌃⌥D"])
        #expect(s.allSatisfy { $0.chord.hotkeyText != nil && $0.chord.mods.count == 2 })
        #expect(s.allSatisfy { KeyMap.leftHand.contains($0.chord.key) || $0.chord.key == "space" })
        #expect(s[1].reason == "free, left hand, the first letter of \"search\"")
        let used: Set<Chord> = [now, Chord(mods: [.opt, .shift], key: "space"), Chord(mods: [.ctrl, .opt], key: "s")]
        let t = KeySuggest.suggestHotkey(action: "Search", used: used, system: [], hyperLabel: "Caps")
        #expect(t.allSatisfy { !used.contains($0.chord) })
        #expect(!KeySuggest.suggestHotkey(action: "Search", used: [], system: [Chord(mods: [.opt, .shift], key: "space")], hyperLabel: "Caps")
            .contains { $0.chord == Chord(mods: [.opt, .shift], key: "space") })
        #expect(KeySuggest.systemChords.isSuperset(of: [Chord(mods: [.cmd], key: "space"), Chord(mods: [.ctrl], key: "space"), Chord(mods: [.cmd], key: "tab"),
                                                         Chord(mods: [.ctrl, .opt], key: "space")]))
    }
}
