import Testing
@testable import SanketaCore

@Suite struct KeySuggestTests {
    let hyper = Set(Modifier.allCases)
    func hy(_ keys: String) -> Set<Chord> { Set(keys.map { Chord(mods: hyper, key: String($0)) }) }

    @Test func prefersFreeKeysNearPartnersOnTheLeft() {
        let used = hy("qwasdfrtcxz")
        let s = KeySuggest.suggest(action: "Toggle bottom pane", mods: hyper, partners: [.leela("hyper+z")!, .leela("hyper+x")!], used: used, hyperLabel: "Caps")
        #expect(s.count == 3)
        #expect(s.allSatisfy { !used.contains($0.chord) })
        // B: 4 + 3 × (1 − 3/4) + 2 + 1.5 = 8.25 beats V and E (7.5 each); C is used, so no free key is within 1.5 of Z or X
        #expect(s.first?.chord.key == "b")
        #expect(s.first?.reason == "free, left hand, the first letter of \"bottom\"")
    }
    @Test func saysWhenAKeyIsNextToItsPartner() {
        let s = KeySuggest.suggest(action: "Toggle pane", mods: hyper, partners: [.leela("hyper+z")!], used: [.leela("hyper+z")!], hyperLabel: "Caps")
        #expect(s.first?.chord.key == "x")
        #expect(s.first?.reason.hasPrefix("free, next to your Caps\u{a0}Z") == true)
    }
    @Test func noFreeKeysGivesNone() {
        let all = Set(KeyMap.position.keys.map { Chord(mods: hyper, key: $0) })
        #expect(KeySuggest.suggest(action: "x", mods: hyper, partners: [], used: all, hyperLabel: "Caps").isEmpty)
    }
    @Test func firstLetterBonusAlone() {
        // no partners; only "p" (right hand) gets the bonus: 4 + 1.5 beats the other right-hand keys at 4
        let s = KeySuggest.suggest(action: "Open pane", mods: hyper, partners: [], used: hy("qwertasdfgzxcvb`12345") , hyperLabel: "Caps", max: 1)
        #expect(s.first?.chord.key == "o")
        #expect(s.first?.score == 5.5)
        #expect(s.first?.reason == "free, the first letter of \"open\"")
    }
    @Test func usedKeysAreNeverOffered() {
        let used = hy("qwertasdfg")
        let s = KeySuggest.suggest(action: "Quit", mods: hyper, partners: [], used: used, hyperLabel: "Caps", max: 100)
        #expect(s.allSatisfy { !used.contains($0.chord) })
        #expect(!s.contains { $0.chord.key == "q" })
    }
    @Test func maxIsRespected() {
        #expect(KeySuggest.suggest(action: "a", mods: hyper, partners: [], used: [], hyperLabel: "Caps", max: 2).count == 2)
        #expect(KeySuggest.suggest(action: "a", mods: hyper, partners: [], used: [], hyperLabel: "Caps", max: 0).isEmpty)
    }
    @Test func keysOutsideTheMapAreNeverOffered() {
        let s = KeySuggest.suggest(action: "Tab", mods: hyper, partners: [], used: [], hyperLabel: "Caps", max: 1000)
        #expect(s.count == KeyMap.position.count)
        #expect(s.allSatisfy { KeyMap.position[$0.chord.key] != nil })
        #expect(!s.contains { $0.chord.key == "tab" })
    }
    @Test func tiesFollowKeyboardOrder() {
        let s = KeySuggest.suggest(action: "", mods: hyper, partners: [], used: [], hyperLabel: "Caps", max: 3)
        #expect(s.map(\.chord.key) == ["`", "1", "2"])
    }
}
