import Testing
@testable import SanketaCore

private func key(_ pack: String, _ title: String, _ detail: String = "x") -> SearchItem {
    SearchItem(packID: pack, packName: pack, kind: .key, title: title, detail: detail)
}

private func doc(_ shelf: String, _ title: String, _ snippet: String = "") -> SearchItem {
    SearchItem(packID: "vault:\(shelf)", packName: shelf, kind: .vault, title: title, detail: snippet)
}

/// One ranking for keys, tips and vault results: `Search.match` and `Search.blend`.
@Suite struct RankingTests {
    @Test func bands() {
        #expect(Search.match("vowel sandhi", doc("learning", "Vowel sandhi")).band == 4, "each word starts a title word")
        #expect(Search.match("lit win", doc("learning", "Split window")).band == 3, "a phrase in the title")
        #expect(Search.match("vowel sandhi", doc("learning", "Vowels", "rules of sandhi")).band == 2, "each word in title or text")
        #expect(Search.match("vowel sandhi", doc("learning", "Garden", "sandhi")).band == 1, "some words")
        #expect(Search.match("vowel sandhi", doc("learning", "Garden", "plants")).band == 0)
        #expect(Search.match("learning", doc("learning", "Garden")).band == 0, "the shelf name is not a match")
        #expect(Search.match("tmux", key("tmux", "Split pane")).band == 2, "a pack name still matches a key")
    }

    @Test func vaultTitleMatchOutranksWeakPackMatches() {
        let packs = [key("tmux", "Sandhi split"), key("fish", "Count lines", "grep vowel sandhi")]
        let vault = [doc("ramabana", "A session", "vowel sandhi here"), doc("learning", "Vowel sandhi")]
        let r = Search.blend("vowel sandhi", packs, vault: vault)
        #expect(r.map(\.title) == ["Vowel sandhi", "Count lines", "A session", "Sandhi split"])
    }

    @Test func titleBeatsSnippetAndVaultRankBreaksTies() {
        let vault = [doc("store", "Garden notes", "sandhi in the garden"), doc("learning", "Sandhi rules"),
                     doc("ramabana", "Sandhi session"), doc("store", "More notes", "sandhi again")]
        #expect(Search.blend("sandhi", [], vault: vault).map(\.title) == ["Sandhi rules", "Sandhi session", "Garden notes", "More notes"])
        // the same band and score: the pack result goes first, and the vault results keep their rank
        let r = Search.blend("sandhi", [key("coach", "Count sandhi lines")], vault: vault)
        #expect(r.map(\.title) == ["Count sandhi lines", "Sandhi rules", "Sandhi session", "Garden notes", "More notes"])
        // a better score in the same band goes first: a word in the title against none
        let s = Search.blend("sandhi rules", [key("coach", "Vowel x", "sandhi rules")], vault: [doc("learning", "Sandhi", "rules")])
        #expect(s.map(\.title) == ["Sandhi", "Vowel x"])
        #expect(Set(s.map { Search.match("sandhi rules", $0).band }) == [2])
    }

    @Test func caseAndDiacriticsDoNotCount() {
        #expect(Search.match("sandhi", doc("learning", "Sāndhi of vowels")).band == 4)
        #expect(Search.match("CAFE", doc("store", "Café hours")).band == 4)
        #expect(Search.match("café", doc("store", "Cafe hours")).band == 4)
        #expect(Search.match("naive", key("p", "x", "a naïve copy")).band == 2)
        #expect(Search.score("resume", key("p", "Résumé the session")) == 30, "the pack scorer too")
        let r = Search.blend("sandhi", [], vault: [doc("store", "Notes", "sandhi"), doc("learning", "SĀNDHI")])
        #expect(r.map(\.title) == ["SĀNDHI", "Notes"])
    }

    @Test func packResultsOfOnePackStayTogetherInABand() {
        let packs = [key("tmux", "Copy mode"), key("vim", "Copy line"), key("tmux", "Copy buffer")]
        #expect(Search.blend("copy", packs).map(\.title) == ["Copy mode", "Copy buffer", "Copy line"])
    }

    @Test func picksStayFirstOnlyWhenNoBetterTitleMatch() {
        let pick = key("tmux", "Split pane left/right"), other = key("vim", "Split window side by side")
        // a question: no title has all the words, so the model's pick stays first
        let q = "how do I split the screen"
        #expect(Search.blend(q, [pick, other], vault: [doc("store", "Screens", "split")], picked: [pick.id]).first == pick)
        // the user types a vault title: the weak pick joins the ranking below it
        let title = doc("learning", "Vowel sandhi rules")
        let weak = key("tmux", "Rules of tmux", "vowel")
        let r = Search.blend("vowel sandhi rules", [weak, other], vault: [title], picked: [weak.id])
        #expect(r.first == title && r.contains(weak))
        // a pick that matches as well as the best title stays first
        let strong = key("vim", "Vowel sandhi rules")
        #expect(Search.blend("vowel sandhi rules", [strong], vault: [title], picked: [strong.id]).map(\.packID) == ["vim", "vault:learning"])
    }
}
