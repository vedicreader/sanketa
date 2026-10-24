import Testing
import Foundation
@testable import SanketaCore

let tmuxTOML = """
id = "tmux"
name = "tmux"
processes = ["tmux"]

[[keys]]
keys = "prefix %"
action = "Split pane left/right"
group = "Panes"

[[keys]]
keys = "prefix c"
action = "New window"

[[tips]]
title = "Zoom a pane"
snippet = "prefix z"
explain = "Toggles the current pane full screen."
tags = ["pane", "zoom"]
"""

let fishTOML = """
id = "fish"
name = "fish"
processes = ["fish"]

[[keys]]
keys = "ctrl+r"
action = "Search history, split by word"

[[tips]]
title = "For loop"
snippet = "for f in *.txt; echo $f; end"
explain = "Iterate over files."
tags = ["iteration"]
"""

func allItems() throws -> [SearchItem] {
    try [tmuxTOML, fishTOML].flatMap { SearchItem.items(from: try PackLibrary.decode(Data($0.utf8))) }
}

struct SearchTests {
    @Test func itemsMapKeysAndTips() throws {
        let items = try allItems()
        let k = try #require(items.first { $0.title == "New window" })
        #expect(k.kind == .key && k.detail == "prefix c" && k.packID == "tmux" && k.id == "tmux|key|New window")
        let t = try #require(items.first { $0.title == "Zoom a pane" })
        #expect(t.kind == .tip && t.detail == "prefix z" && t.explain == "Toggles the current pane full screen." && t.tags == ["pane", "zoom"])
    }

    @Test func splitPaneFindsTmux() throws {
        let r = Search.rank("split pane", try allItems(), context: [])
        #expect(r.first?.title == "Split pane left/right")
        #expect(!r.contains { $0.title == "New window" })
    }

    @Test func allTokensRequired() throws {
        let items = try allItems()
        let split = try #require(items.first { $0.title == "Split pane left/right" })
        #expect(Search.score("split banana", split) == nil)
        #expect(Search.score("split pane", split) != nil)
        #expect(Search.rank("split banana", items, context: []).isEmpty)
    }

    @Test func scoringTiers() throws {
        let items = try allItems()
        let zoom = try #require(items.first { $0.title == "Zoom a pane" })
        let fish = try #require(items.first { $0.title == "For loop" })
        #expect(Search.score("zoom", zoom) == 30)       // word prefix in title
        #expect(Search.score("oom", zoom) == 20)        // substring in title
        #expect(Search.score("toggles", zoom) == nil)   // explain is not searched
        #expect(Search.score("tmux", zoom) == 10)       // pack name
        #expect(Search.score("iteration", fish) == 10)       // tag
        #expect(Search.score("prefix", zoom) == 10)     // detail
        #expect(Search.score("zmp", zoom) == 3)         // subsequence in title
        #expect(Search.score("ZOOM", zoom) == 30)       // case-insensitive
    }

    @Test func contextPacksRankFirst() throws {
        let items = try allItems()
        let r = Search.rank("split", items, context: ["tmux"])
        #expect(r.map(\.packID) == ["tmux", "fish"])
        let r2 = Search.rank("split", items, context: ["fish"])
        #expect(r2.map(\.packID) == ["fish", "tmux"])
    }

    @Test func emptyQueryReturnsContext() throws {
        let items = try allItems()
        let r = Search.rank("  ", items, context: ["fish", "tmux"])
        #expect(r.map(\.packID) == ["fish", "fish", "tmux", "tmux", "tmux"])
        #expect(Search.rank("", items, context: []).isEmpty)
    }

    @Test func localSearchWrapsRank() throws {
        let items = try allItems()
        let p: SearchProviding = LocalSearch()
        #expect(p.results("zoom", items, context: []) == Search.rank("zoom", items, context: []))
    }
}
