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
    @Test func leelaTextRoundTripsInLeelaNames() {
        for c in [Chord(mods: [.cmd], key: "k"), Chord(mods: [.cmd, .shift, .opt], key: "p"), Chord(mods: [], key: "esc"), Chord(mods: Set(Modifier.allCases), key: "left"),
                  Chord(mods: [.ctrl], key: "f12"), Chord(mods: [.opt], key: "delete"), Chord(mods: [.cmd], key: "+")] {
            #expect(Chord.leela(c.leelaText!) == c, "\(c)")
        }
        #expect(Chord(mods: [.cmd, .shift], key: "p").leelaText == "mod+shift+p")
        #expect(Chord(mods: [.cmd, .ctrl, .opt, .shift], key: "k").leelaText == "hyper+k")
        #expect(Chord(mods: [.opt], key: "esc").leelaText == "alt+escape")
        #expect(Chord(mods: [.ctrl], key: "f13").leelaText == nil && Chord(mods: [.ctrl], key: "insert").leelaText == nil)
    }
    @Test func capitalKeyNamesFold() {
        #expect(Chord.leela("hyper+Left") == Chord.leela("hyper+left"))
        #expect(Chord.leela("alt+Tab") == Chord.leela("alt+tab") && Chord.leela("alt+PageUp") == Chord.leela("alt+pageup"))
        #expect(Chord.aerospace("alt-leftSquareBracket") == Chord(mods: [.opt], key: "[") && Chord.aerospace("alt-pageUp")?.key == "pageup")
    }
    @Test func aeroSpaceForwardDelete() {
        let c = Chord(mods: [.cmd], key: "delete")
        #expect(c.aerospaceText == "cmd-forwardDelete" && Chord.aerospace("cmd-forwardDelete") == c)
        #expect(Chord.aerospace("cmd-backspace")?.key == "backspace")
    }
}
