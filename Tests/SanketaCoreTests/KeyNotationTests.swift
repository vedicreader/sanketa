import Testing
@testable import SanketaCore

struct KeyNotationTests {
    @Test func tmuxNotation() {
        #expect(KeyNotation.display("prefix %", prefix: "C-b") == "⌃B  %")
        #expect(KeyNotation.display("prefix c", prefix: "C-a") == "⌃A  c")
        #expect(KeyNotation.display("prefix C", prefix: "C-b") == "⌃B  C")
        #expect(KeyNotation.display("C-M-x") == "⌃⌥X")
        #expect(KeyNotation.display("M-B") == "⌥⇧B")
        #expect(KeyNotation.display("prefix M-Up", prefix: "C-b") == "⌃B  ⌥↑")
        #expect(KeyNotation.display("prefix C-Left", prefix: "C-b") == "⌃B  ⌃←")
        #expect(KeyNotation.display("S-Right") == "⇧→")
        #expect(KeyNotation.display("prefix PPage", prefix: "C-b") == "⌃B  pgup")
        #expect(KeyNotation.display("NPage") == "pgdn")
        #expect(KeyNotation.display("prefix Space", prefix: "C-b") == "⌃B  space")
        #expect(KeyNotation.display("BSpace") == "⌫" && KeyNotation.display("Enter") == "↩")
        #expect(KeyNotation.display("Escape") == "esc" && KeyNotation.display("Tab") == "tab" && KeyNotation.display("BTab") == "⇧tab")
        #expect(KeyNotation.display("DC") == "del" && KeyNotation.display("IC") == "ins")
        #expect(KeyNotation.display("prefix -", prefix: "C-b") == "⌃B  -")
        #expect(KeyNotation.display("C--") == "⌃-")
        #expect(KeyNotation.display("prefix z") == "prefix  z")
    }

    @Test func plusNotationAndPassThrough() {
        #expect(KeyNotation.display("ctrl+r") == "⌃R")
        #expect(KeyNotation.display("alt+right") == "⌥→")
        #expect(KeyNotation.display("ctrl+opt+k") == "⌃⌥K")
        #expect(KeyNotation.display("⌘N") == "⌘N")
        #expect(KeyNotation.display("⇧⌘S") == "⇧⌘S")
        #expect(KeyNotation.display("F6") == "F6")
        #expect(KeyNotation.display("q") == "q")
        #expect(KeyNotation.display("+") == "+")
        #expect(KeyNotation.display("a+b") == "a+b")
    }

    /// Obscure glyphs read as words; ⌘ ⌥ ⇧ ⌃, arrows, ↩ and ⌫ stay symbols.
    @Test func obscureGlyphsBecomeWords() {
        for esc in ["Esc", "Escape", "⎋", "escape"] { #expect(KeyNotation.display(esc) == "esc", "\(esc)") }
        #expect(KeyNotation.display("Esc Esc") == "esc  esc")
        #expect(KeyNotation.display("F10 / q / ⎋") == "F10  /  q  /  esc")
        #expect(KeyNotation.display("⇥ ⇥") == "tab  tab" && KeyNotation.display("↩ / ⇥") == "↩  /  tab")
        #expect(KeyNotation.display("⌦") == "del" && KeyNotation.display("⇞") == "pgup" && KeyNotation.display("⇟") == "pgdn")
        #expect(KeyNotation.display("⌥PgUp") == "⌥pgup" && KeyNotation.display("PgUp / PgDn") == "pgup  /  pgdn")
        #expect(KeyNotation.display("⌥/ / ⌃Space") == "⌥/  /  ⌃space")
        #expect(KeyNotation.display("⌘Home") == "⌘home" && KeyNotation.display("⌘End") == "⌘end")
        #expect(KeyNotation.display("⌃⎋") == "⌃esc" && KeyNotation.display("shift+tab") == "⇧tab")
        #expect(KeyNotation.display("↑ ↓ ← → ↩ ⌫") == "↑  ↓  ←  →  ↩  ⌫")
        #expect(KeyNotation.display("⌘⇧P") == "⇧⌘P")      // modifiers in Apple's order
    }

    @Test func functionKeysUppercase() {
        #expect(KeyNotation.display("ctrl+opt+f5") == "⌃⌥F5")
        #expect(KeyNotation.display("f12") == "F12" && KeyNotation.display("C-f3") == "⌃F3")
        #expect(KeyNotation.display("fish") == "fish")
    }

    /// Option-layer letters are what the key types; upper-casing them would suggest a shift that isn't there.
    @Test func nonASCIILettersKeepTheirCase() {
        #expect(KeyNotation.display("alt+å") == "⌥å" && KeyNotation.display("alt+ß") == "⌥ß")
        #expect(KeyNotation.display("alt+q") == "⌥Q")
    }
}
