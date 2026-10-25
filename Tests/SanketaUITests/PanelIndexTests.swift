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

    /// The memory fallback is a note: the footer shows it, but not as a file that did not load.
    @Test func configNoteIsNotAnError() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        let d = try tempURL("x").deletingLastPathComponent().appendingPathComponent("config.toml")
        try "[llm]\non_device = true\nmlx_model = \"gemma-4-e4b\"\n".write(to: d, atomically: true, encoding: .utf8)
        let (_, err, note) = Config.load(d, memory: 8 << 30, installed: { $0 == .qwen4b })
        m.configError = err.map { PackLoadError(file: d.path, message: $0) }
        m.configNote = note
        #expect(m.showsFooter && m.errorLines.isEmpty)
        #expect(m.configNote == "Gemma 4 E4B needs 16 GB of memory. This Mac has 8 GB. Sanketa uses Qwen3.5-4B.")
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

/// Menu keys come in menu-bar order (app menu, File, Edit, View, …): the useful ones are far down, so a menu section
/// never folds. Regression: Chrome showed 18 of 79 keys and Finder 2 of its 6 groups.
@MainActor struct PanelMenuFoldTests {
    func model() throws -> PanelModel { PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1) }

    static let chromeMenu = MenuKeys.pack(bundleID: "com.google.Chrome", name: "Google Chrome", shortcuts: [
        (["Chrome", "Settings…"], "⌘,"), (["Chrome", "Hide Google Chrome"], "⌘H"), (["Chrome", "Quit Google Chrome"], "⌘Q"),
        (["File", "New Tab"], "⌘T"), (["File", "New Window"], "⌘N"), (["File", "Close Tab"], "⌘W"),
        (["Edit", "Copy"], "⌘C"), (["Edit", "Paste"], "⌘V"), (["Edit", "Find…"], "⌘F"),
        (["View", "Reload This Page"], "⌘R"), (["View", "Enter Full Screen"], "⌃⌘F"), (["View", "Developer Tools"], "⌥⌘I"),
        (["History", "Back"], "⌘["), (["History", "Forward"], "⌘]"), (["History", "Show Full History"], "⌘Y"),
        (["Tab", "Select Next Tab"], "⌃tab"), (["Tab", "Select Previous Tab"], "⌃⇧tab"), (["Tab", "Pin Tab"], "⌥⌘P"),
    ].map { MenuShortcut(path: $0.0, keys: $0.1) })

    func shown(_ m: PanelModel, _ s: LayerSectionData) -> Int { s.groups.filter { !m.isFolded(s, $0) }.reduce(0) { $0 + $1.keys.count } }

    @Test func menuPackOpensEveryGroup() throws {
        let m = try model()
        let app = Layer(kind: .app, name: "Google Chrome", packID: Self.chromeMenu.id)
        m.update(Context(appName: "Google Chrome", bundleID: "com.google.Chrome", layers: [app], packs: [Self.chromeMenu], axTrusted: true))
        let s = try #require(m.sections.first)
        #expect(s.groups.map(\.name) == ["Chrome", "File", "Edit", "View", "History", "Tab"])
        #expect(s.groups.allSatisfy { $0.folds })
        #expect(s.groups.allSatisfy { !m.isFolded(s, $0) })
        #expect(shown(m, s) == Self.chromeMenu.keys.count)
        // a click still folds a group
        m.toggle(s, s.groups[3]); #expect(m.isFolded(s, s.groups[3]))
    }

    /// Leela in a Chrome tab: the Leela section comes first and folds as an index; Chrome's keys stay open below it.
    @Test func hostedPackKeepsTheHostMenuOpen() throws {
        let lib = PackLibrary.load(bundled: bundledPacks, user: nil)
        let title = "leela — orgs - Google Chrome"
        let layers = LayerResolver(library: lib, tmux: TmuxQuery(runner: ProcessRunner()), remote: nil)
            .resolveApp(bundleID: "com.google.Chrome", name: "Google Chrome", title: title)
        try #require(layers.map(\.packID) == ["leela", Self.chromeMenu.id])
        let packs = [try #require(lib.packs["leela"]), Self.chromeMenu]
        let m = try model()
        m.update(Context(appName: "Google Chrome", bundleID: "com.google.Chrome",
                         layers: LayerResolver.applyContexts(layers, packs: packs, title: title), packs: packs, axTrusted: true))
        let leela = m.sections[0], chrome = m.sections[1]
        #expect(leela.groups.contains { m.isFolded(leela, $0) }, "the hosted pack is still an index")
        #expect(chrome.groups.allSatisfy { !m.isFolded(chrome, $0) })
        #expect(shown(m, chrome) == Self.chromeMenu.keys.count)
    }

    /// A terminal tool stack is still an index, the terminal's own menu keys too: the tool in front stands out.
    @Test func terminalStackStaysAnIndex() throws {
        let menu = MenuKeys.pack(bundleID: "com.apple.Terminal", name: "Terminal", shortcuts: Self.chromeMenu.keys.map {
            MenuShortcut(path: [$0.group ?? "", $0.action], keys: $0.keys) })
        var c = try bundledContext(["htop", "tmux", "fish", "Terminal"])
        c.packs[3] = menu
        c.layers[3].packID = menu.id
        let m = try model()
        m.update(c)
        let htop = m.sections[0], tmux = m.sections[1], term = try #require(m.sections.last)
        #expect(htop.groups.dropFirst(2).contains { m.isFolded(htop, $0) })
        #expect(tmux.groups.dropFirst().allSatisfy { m.isFolded(tmux, $0) })
        #expect(term.layer.kind == .terminal && term.groups.count == 6)
        #expect(!m.isFolded(term, term.groups[0]) && term.groups.dropFirst().allSatisfy { m.isFolded(term, $0) })
        // alone (no shell found), the terminal's menu is still an index: the first section opens 2 groups
        let alone = Context(appName: "Terminal", bundleID: "com.apple.Terminal", layers: [c.layers[3]], packs: [menu], axTrusted: true)
        m.update(alone)
        let s = m.sections[0]
        #expect(s.groups.prefix(2).allSatisfy { !m.isFolded(s, $0) } && s.groups.dropFirst(2).allSatisfy { m.isFolded(s, $0) })
    }
}

/// The real path that broke: ContextEngine reads the real Finder's menus, and the panel shows every key of them.
@MainActor @Suite(.serialized) struct PanelRealAppTests {
    @Test(.enabled(if: AXIsProcessTrusted(), "Accessibility not granted to the test runner"))
    func finderShowsEveryMenuGroup() throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let lib = PackLibrary.load(bundled: bundledPacks, user: nil)
        let c = ContextEngine(config: Config(), library: lib).compute(pid: finder.processIdentifier, bundleID: "com.apple.finder", appName: "Finder")
        let menu = try #require(c.packs.first { $0.id == "app:com.apple.finder" })
        try #require(menu.keys.count > 20 && Set(menu.keys.compactMap(\.group)).count >= 4, "Finder's menus: \(menu.keys.count) keys")
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(c)
        let s = try #require(m.sections.first)
        #expect(m.sections.count == 1)
        #expect(s.groups.allSatisfy { !m.isFolded(s, $0) }, "folded: \(s.groups.filter { m.isFolded(s, $0) }.map(\.id))")
        #expect(s.groups.filter { !m.isFolded(s, $0) }.reduce(0) { $0 + $1.keys.count } == menu.keys.count)
    }

    /// Leela hosted in the real Finder's window (a test pack lists Finder in `title_apps`): Finder's menu stays open.
    @Test(.enabled(if: AXIsProcessTrusted(), "Accessibility not granted to the test runner"))
    func hostedSectionKeepsRealMenuOpen() throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        var lib = PackLibrary.load(bundled: bundledPacks, user: nil)
        var leela = try #require(lib.packs["leela"])
        leela.titleApps = ["com.apple.finder"]
        lib.packs["leela"] = leela
        let e = ContextEngine(config: Config(), library: lib)
        let title = "leela — orgs"
        let layers = LayerResolver(library: lib, tmux: TmuxQuery(runner: ProcessRunner()), remote: nil)
            .resolveApp(bundleID: "com.apple.finder", name: "Finder", title: title)
        try #require(layers.map(\.packID) == ["leela", "app:com.apple.finder"])
        let menu = e.appPack(pid: finder.processIdentifier, bundleID: "com.apple.finder", name: "Finder", trusted: true)
        try #require(menu.keys.count > 20)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(Context(appName: "Finder", bundleID: "com.apple.finder", layers: layers, packs: [leela, menu], axTrusted: true))
        let s = try #require(m.sections.last)
        #expect(s.pack.id == "app:com.apple.finder" && s.groups.allSatisfy { !m.isFolded(s, $0) })
        #expect(s.groups.reduce(0) { $0 + $1.keys.count } == menu.keys.count)
    }
}
