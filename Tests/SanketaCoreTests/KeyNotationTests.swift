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
        #expect(KeyNotation.display("prefix PPage", prefix: "C-b") == "⌃B  PgUp")
        #expect(KeyNotation.display("NPage") == "PgDn")
        #expect(KeyNotation.display("prefix Space", prefix: "C-b") == "⌃B  Space")
        #expect(KeyNotation.display("BSpace") == "⌫" && KeyNotation.display("Enter") == "↩")
        #expect(KeyNotation.display("Escape") == "⎋" && KeyNotation.display("Tab") == "⇥")
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
}
