import AppKit
import SwiftUI
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

let bundledPacks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Packs")

/// htop › tmux › fish › Terminal with the real bundled packs.
func bundledContext(_ names: [String]) throws -> Context {
    let lib = PackLibrary.load(bundled: bundledPacks, user: nil)
    let layers = names.map { n -> Layer in
        switch n {
        case "Terminal": Layer(kind: .terminal, name: n, packID: terminal.id)
        case "tmux": Layer(kind: .multiplexer, name: n, packID: n)
        case "fish", "bash": Layer(kind: .shell, name: n, packID: n)
        default: Layer(kind: .program, name: n, packID: n)
        }
    }
    return Context(appName: "Terminal", bundleID: "com.apple.Terminal", layers: layers,
                   packs: try names.map { $0 == "Terminal" ? terminal : try #require(lib.packs[$0]) }, axTrusted: true)
}

/// The panel is an index of the stack (design review P1), and it stays calm on quick pane switches (P4).
@MainActor struct PanelIndexTests {
    func model(_ seed: UInt64 = 1) throws -> PanelModel { PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: seed) }

    @Test func firstSectionOpensTwoGroupsOthersOne() throws {
        let m = try model()
        m.update(try bundledContext(["htop", "tmux", "fish", "Terminal"]))
        let htop = m.sections[0], tmux = m.sections[1]
        #expect(htop.groups.prefix(2).allSatisfy { !m.isFolded(htop, $0) })
        for g in htop.groups.dropFirst(2) { #expect(m.isFolded(htop, g) == (g.keys.count > 2), "\(g.id)") }
        #expect(tmux.groups.first?.name == "Panes" && !m.isFolded(tmux, tmux.groups[0]))
        #expect(tmux.groups[0].keys.contains { $0.action == "Split pane left/right" })
        #expect(tmux.groups.dropFirst().allSatisfy { m.isFolded(tmux, $0) })
        // a click opens a folded group and closes it again; a small group never folds
        let view = htop.groups[2]
        m.toggle(htop, view); #expect(!m.isFolded(htop, view))
        m.toggle(htop, view); #expect(m.isFolded(htop, view))
        let small = RowGroup(name: "Two", keys: Array(htop.groups[0].keys.prefix(2)))
        m.toggle(htop, small); #expect(!small.folds && !m.isFolded(htop, small))
    }

    /// The folded stack, drawn by the real section views, is less than half the height of the fully open one.
    @Test func foldedStackIsShort() throws {
        let m = try model()
        m.update(try bundledContext(["htop", "tmux", "fish", "Terminal"]))
        func height(_ folded: @escaping (LayerSectionData, RowGroup) -> Bool) -> CGFloat {
            let v = VStack(alignment: .leading, spacing: Theme.sectionGap) {
                ForEach(m.sections) { s in LayerSection(data: s, collapsed: false, folded: { folded(s, $0) }) {} }
            }.frame(width: 312)
            let r = ImageRenderer(content: v)
            return r.cgImage.map { CGFloat($0.height) } ?? 0
        }
        let index = height { m.isFolded($0, $1) }, open = height { _, _ in false }
        #expect(index > 0 && index < open / 2, "index \(index) pt, open \(open) pt")
        #expect(index < 1_600, "the four-layer index is \(index) pt high")
    }

    @Test func tipCardStaysWhilePackIsInTheStack() throws {
        for seed in 0..<10 as Range<UInt64> {
            let m = try model(seed)
            m.update(try bundledContext(["fish", "Terminal"]))
            let card = try #require(m.tipCards.first)
            #expect(card.packID == "fish")
            m.update(try bundledContext(["htop", "fish", "Terminal"]))
            #expect(m.tipCards == [card], "a new tool in front keeps the card of a layer that is still there")
            m.update(try bundledContext(["htop", "tmux", "bash"]))
            #expect(m.tipCards.count == 1 && m.tipCards != [card] && ["htop", "tmux", "bash"].contains(m.tipCards[0].packID))
            m.rotate()                                      // the timer still changes it
            #expect(m.tipCards.count == 1)
        }
    }

    /// A → B → A finds A's folds and scroll offset again; the tool in front still opens.
    @Test func quickSwitchKeepsFoldsAndScroll() throws {
        let m = try model()
        let a = try bundledContext(["htop", "tmux", "fish", "Terminal"]), b = try bundledContext(["yazi", "fish", "Terminal"])
        m.update(a)
        let htop = m.sections[0]
        m.toggle(htop, htop.groups[2])
        m.toggle(htop.id)
        m.scrollOffset = 420
        let t0 = m.scrollToken
        m.update(b)
        #expect(m.scrollToken == t0 + 1 && m.scrollTarget == 0 && m.folds.isEmpty && m.collapsed.isEmpty)
        m.scrollOffset = 90
        m.update(a)
        #expect(m.scrollToken == t0 + 2 && m.scrollTarget == 420)
        #expect(!m.isFolded(m.sections[0], m.sections[0].groups[2]))
        #expect(m.collapsed.isEmpty, "the tool in front opens again")
        m.update(b)
        #expect(m.scrollTarget == 90)
        let same = m.scrollToken
        m.update(b)                                         // a repeat poll changes nothing
        #expect(m.scrollToken == same)
    }

    @Test func remembersTheLastEightStacks() throws {
        let m = try model()
        let tools = ["htop", "yazi", "vim", "git", "lazygit", "nvtop", "grep", "awk", "sed", "find"]
        m.update(try bundledContext([tools[0], "fish", "Terminal"]))
        m.scrollOffset = 100
        for t in tools.dropFirst() { m.update(try bundledContext([t, "fish", "Terminal"])); m.scrollOffset = 5 }
        #expect(m.memory.count == PanelModel.rememberedStacks)
        m.update(try bundledContext([tools[0], "fish", "Terminal"]))
        #expect(m.scrollTarget == 0, "the oldest stack is forgotten")
        m.update(try bundledContext([tools[9], "fish", "Terminal"]))
        #expect(m.scrollTarget == 5)
    }
}

/// Search results read like the list: one heading per pack, one row per key (design review P3).
@MainActor struct SearchResultsTests {
    @Test func resultsOfAPackStayTogether() throws {
        let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
        s.setSource(library: PackLibrary.load(bundled: bundledPacks, user: nil), context: try bundledContext(["htop", "tmux", "fish", "Terminal"]))
        for q in ["pane", "e", "file", "split"] {
            s.query = q
            try #require(!s.results.isEmpty, "\(q)")
            var runs = [String]()
            for r in s.results where runs.last != r.packID { runs.append(r.packID) }
            #expect(Set(runs).count == runs.count, "\(q): a pack heading shows twice: \(runs)")
            #expect(s.selection == 0 && s.selected == s.results.first)
        }
        s.query = "split pane"
        #expect(s.results.first?.title == "Split pane left/right" && !s.results.contains { $0.packID == "sed" })
        // keys found by their key text stay: tab and esc
        s.query = "tab"
        #expect(s.results.contains { $0.kind == .key && $0.detail.lowercased().contains("tab") && !$0.title.lowercased().contains("tab") })
        s.query = "esc"
        #expect(s.results.contains { $0.kind == .key && $0.detail.contains("esc") && !$0.title.lowercased().contains("esc") })
    }

    @Test func noResultTextIsPlainAndSaysWhatToDo() {
        #expect(ResultsList.noResult("zzq ") == "No result for \u{201C}zzq\u{201D}.")
        #expect(ResultsList.noResultHelp == "Search finds keys and tips in all packs. Press esc to close.")
    }
}

/// The footer names each file that did not load, in words, and a click opens it (P6).
@MainActor struct FooterTests {
    func err(_ name: String, _ m: String) -> PackLoadError { PackLoadError(file: "/tmp/sanketa-test/packs/\(name)", message: m) }

    @Test func oneReadableLinePerBadFile() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        #expect(m.errorLines.isEmpty && !m.showsFooter)
        m.packErrors = [err("duckdb.toml", "key 2 has no action")]
        m.configError = PackLoadError(file: "/tmp/sanketa-test/config.toml", message: "line 1: hotkey must be a string")
        #expect(m.showsFooter)
        #expect(m.errorLines == [
            .init(text: "config.toml: line 1: hotkey must be a string.", action: .open("/tmp/sanketa-test/config.toml")),
            .init(text: "duckdb.toml: key 2 has no action.", action: .open("/tmp/sanketa-test/packs/duckdb.toml")),
        ])
    }

    @Test func manyBadFilesShowACountUntilClicked() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.packErrors = [err("a.toml", "key 1 has no keys"), err("b.toml", "the pack has no id"), err("c.toml", "line 3: syntax error")]
        #expect(m.errorLines == [.init(text: "3 pack files did not load. Click to see them.", action: .showAll)])
        m.showAllErrors = true
        #expect(m.errorLines.map(\.text) == ["a.toml: key 1 has no keys.", "b.toml: the pack has no id.", "c.toml: line 3: syntax error."])
        m.packErrors = m.packErrors                     // the same set (a reload with no change) keeps the list open
        #expect(m.showAllErrors)
        m.packErrors.append(err("d.toml", "the pack has no name"))
        #expect(!m.showAllErrors && m.errorLines.count == 1)
    }

    /// The real loader's messages reach the footer as they are, from a broken pack on disk.
    @Test func loaderMessagesReachTheFooter() throws {
        let d = try tempURL("x").deletingLastPathComponent()
        try "id = \"duckdb\"\nname = \"DuckDB\"\n\n[[keys]]\nkeys = \"⌃D\"\naction = \"Quit\"\n\n[[keys]]\nkeys = \".tables\"\n"
            .write(to: d.appendingPathComponent("duckdb.toml"), atomically: true, encoding: .utf8)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.packErrors = PackLibrary.load(bundled: d, user: nil).errors
        #expect(m.errorLines.map(\.text) == ["duckdb.toml: key 2 has no action."])
    }
}
