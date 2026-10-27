import Testing
@testable import SanketaCore

@Suite struct ChordTests {
    @Test func parsesAeroSpace() {
        #expect(Chord.aerospace("cmd-alt-ctrl-shift-h") == Chord(mods: [.cmd, .opt, .ctrl, .shift], key: "h"))
        #expect(Chord.aerospace("alt-ctrl-shift-1")?.mods == [.opt, .ctrl, .shift])
        #expect(Chord.aerospace("cmd-alt-ctrl-shift-leftSquareBracket")?.key == "[")
        #expect(Chord.aerospace("ctrl-cmd-backtick")?.key == "`")
        #expect(Chord.aerospace("alt-shift-semicolon")?.key == ";")
        #expect(Chord.aerospace("cmd-alt-ctrl-shift-keypad7")?.key == "keypad7")   // unknown names stay
    }
    @Test func parsesLeelaAndSanketa() {
        #expect(Chord.leela("hyper+z") == Chord(mods: Set(Modifier.allCases), key: "z"))
        #expect(Chord.leela("mod+shift+k") == Chord(mods: [.cmd, .shift], key: "k"))
        #expect(Chord.sanketa("Caps\u{a0}Z") == Chord.leela("hyper+z"))
        #expect(Chord.sanketa("⌃⌥⇧⌘X") == Chord.leela("hyper+x"))
        #expect(Chord.sanketa("⌥⇧B") == Chord.leela("alt+shift+b"))
    }
    @Test func leelaUpperCaseLetterMeansShift() {
        // as LeelaKeymap.render reads it
        #expect(Chord.leela("N") == Chord(mods: [.shift], key: "n"))
        #expect(Chord.leela("alt+N") == Chord(mods: [.opt, .shift], key: "n"))
        #expect(Chord.leela("n") == Chord(mods: [], key: "n"))
        #expect(Chord.leela("hyper+Z") == Chord.leela("hyper+z"))
        #expect(Chord.leela("F5") == Chord(mods: [], key: "f5"))
    }
    @Test func formatsBack() {
        let c = Chord.aerospace("cmd-alt-ctrl-shift-leftSquareBracket")!
        #expect(c.display() == "Caps\u{a0}[")
        #expect(c.aerospaceText == "cmd-alt-ctrl-shift-leftSquareBracket")
        #expect(Chord.leela("alt+shift+b")!.display() == "⌥⇧B")
        #expect(Chord.leela("hyper+z")!.leelaText == "hyper+z")
        #expect(Chord(mods: [.opt, .ctrl], key: "1").aerospaceText == "alt-ctrl-1")
    }
}
