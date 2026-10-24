import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

let tmuxTOML = """
id = "tmux"
name = "tmux"
processes = ["tmux"]
prefix = "C-b"

[[keys]]
keys = "prefix %"
action = "Split pane left/right"
group = "Panes"

[[keys]]
keys = "prefix c"
action = "New window"
group = "Windows"

[[keys]]
keys = "prefix z"
action = "Zoom pane"
group = "Panes"
"""

let fishTOML = """
id = "fish"
name = "fish"
processes = ["fish"]

[[keys]]
keys = "alt+right"
action = "Accept autosuggestion word"

[[tips]]
title = "Loop over files"
snippet = "for f in *.log; echo $f; end"
explain = "fish for-loop; no do/done needed"
tags = ["loops"]
"""

let htopTOML = """
id = "htop"
name = "htop"
processes = ["htop"]

[[keys]]
keys = "F6"
action = "Sort by column"
"""

func packs() throws -> [String: Pack] {
    Dictionary(uniqueKeysWithValues: try [tmuxTOML, fishTOML, htopTOML].map { try PackLibrary.decode(Data($0.utf8)) }.map { ($0.id, $0) })
}

func tempURL(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent(name)
}

let terminal = MenuKeys.pack(bundleID: "com.apple.Terminal", name: "Terminal",
                             shortcuts: [MenuShortcut(path: ["Shell", "New Window"], keys: "⌘N")])

func context(_ names: [String]) throws -> Context {
    let p = try packs()
    let layers = names.map { n -> Layer in
        switch n {
        case "Terminal": Layer(kind: .terminal, name: n, packID: terminal.id)
        case "tmux": Layer(kind: .multiplexer, name: n, packID: n)
        case "fish": Layer(kind: .shell, name: n, packID: n)
        default: Layer(kind: .program, name: n, packID: n)
        }
    }
    return Context(appName: "Terminal", bundleID: "com.apple.Terminal", layers: layers,
                   packs: names.map { $0 == "Terminal" ? terminal : p[$0]! }, axTrusted: true)
}

@MainActor func controller() throws -> PanelController {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let model = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
    let search = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
    search.setSource(library: PackLibrary(packs: try packs()))
    return PanelController(model: model, search: search)
}

/// CPU time of the calling thread; the panel's SwiftUI and AppKit work runs on the main thread.
func threadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, port) }
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    return Double(info.user_time.seconds + info.system_time.seconds)
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
}

@MainActor @Suite(.serialized) struct PanelTests {
    @Test func visiblePanelIdlesWithoutCPU() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.model.update(try context(["htop", "tmux", "fish", "Terminal"]))
        c.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let t0 = threadCPUSeconds()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        #expect(threadCPUSeconds() - t0 < 0.1)   // main thread under ~3% over 3 s, generous for a loaded machine
    }

    @Test func markLoadsAsTemplateFromBrandFolder() throws {
        let img = try #require(Brand.mark())
        #expect(img.isTemplate && img.size == NSSize(width: 15, height: 15))
        #expect(img.representations.map(\.pixelsWide).sorted() == [18, 36, 54])
        // a folder with only the 1x file still gives a mark; an empty folder gives none
        let d = try tempURL("x").deletingLastPathComponent()
        try FileManager.default.copyItem(at: Brand.directory().appendingPathComponent("sanketa-mark.png"),
                                         to: d.appendingPathComponent("sanketa-mark.png"))
        #expect(Brand.mark(in: d)?.representations.count == 1)
        #expect(Brand.mark(in: try tempURL("y").deletingLastPathComponent()) == nil)
    }

    /// The mark and the breadcrumb share one 32 pt row in the title bar; the search field follows 6 pt below it,
    /// with no dead space. Clicks pass through the mark, and the breadcrumb gets its clicks.
    @Test func topRowHoldsMarkAndBreadcrumb() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.model.update(try context(["htop", "tmux", "fish", "Terminal"]))
        c.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let root = try #require(c.panel.contentView)
        root.layoutSubtreeIfNeeded()
        let h = root.bounds.height
        #expect(c.mark.isDescendant(of: root) && c.mark.image?.isTemplate == true)
        let f = c.mark.convert(c.mark.bounds, to: nil)
        #expect(abs(f.minX - Theme.pad) < 0.5 && abs(f.width - 15) < 0.5 && abs(f.height - 15) < 0.5, "\(f)")
        #expect(abs(f.midY - (h - Theme.topRow / 2)) <= 0.5, "mark centre \(h - f.midY) pt from the top")
        let field = c.field.convert(c.field.bounds, to: nil)
        #expect(abs((h - field.maxY) - (Theme.topRow + Theme.fieldGap)) < 1, "field top \(h - field.maxY) pt from the top")
        let frame = try #require(root.superview)        // the window frame view, with the title bar views
        let atMark = frame.hitTest(frame.convert(NSPoint(x: f.midX, y: f.midY), from: nil))
        #expect(atMark !== c.mark)
        let crumb = frame.hitTest(frame.convert(NSPoint(x: f.maxX + 7 + 8, y: f.midY), from: nil))
        #expect(crumb?.isDescendant(of: root) == true, "the title bar takes the breadcrumb click: \(String(describing: crumb))")
        #expect(!c.panel.isKeyWindow && !NSApp.isActive)
    }

    @Test func panelShowDoesNotStealFocus() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.show()
        #expect(c.panel.isVisible)
        #expect(NSApp.keyWindow !== c.panel)
        #expect(!c.panel.isKeyWindow)
        #expect(!NSApp.isActive)
        #expect(c.panel.contentView is NSGlassEffectView && !c.panel.isOpaque)
    }

    @Test func beginSearchMakesPanelKeyAndEndSearchResigns() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.show()
        c.beginSearch(previousApp: nil)
        #expect(c.panel.isKeyWindow)
        #expect(c.field.currentEditor() != nil && c.panel.firstResponder === c.field.currentEditor())
        // typing goes through the field into the search model
        (c.field.currentEditor() as? NSTextView)?.insertText("split", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(c.search.query == "split")
        #expect(c.search.selected?.title == "Split pane left/right")
        c.endSearch()
        #expect(!c.panel.isKeyWindow)
        #expect(c.panel.isVisible)
        #expect(c.search.query.isEmpty && c.field.stringValue.isEmpty && c.search.results.isEmpty)
        #expect(!c.searching)
    }

    @Test func returnCopiesAndEscapeEnds() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.beginSearch(previousApp: nil)
        let ed = try #require(c.field.currentEditor() as? NSTextView)
        ed.insertText("pane", replacementRange: NSRange(location: NSNotFound, length: 0))
        ed.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(c.search.selected?.title == "Zoom pane")
        ed.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(c.search.pasteboard.string(forType: .string) == "prefix z")
        #expect(!c.panel.isKeyWindow && !c.searching)
        c.beginSearch(previousApp: nil)
        try #require(c.field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!c.panel.isKeyWindow && !c.searching && c.panel.isVisible)
    }

    @Test func hotkeyRegistersAndConflictReturnsFalse() throws {
        let a = HotkeyCenter(), b = HotkeyCenter()
        defer { a.unregisterAll(); b.unregisterAll() }
        let h = try #require(Hotkey.parse("ctrl+opt+cmd+shift+f12"))
        #expect(h.keyCode == UInt32(kVK_F12))
        #expect(a.register(h) {})
        #expect(!b.register(h) {})
        a.unregisterAll()
        #expect(b.register(h) {})
    }

    @Test func searchModelCopiesSelectedDetail() throws {
        let pb = NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let s = SearchModel(pasteboard: pb)
        s.setSource(library: PackLibrary(packs: try packs()), context: try context(["fish", "Terminal"]))
        s.query = "split"
        let first = try #require(s.results.first)
        #expect(first.packID == "tmux" && first.title == "Split pane left/right" && first.detail == "prefix %")
        #expect(s.activate() == first)
        #expect(pb.string(forType: .string) == "prefix %")
        s.query = "pane"
        #expect(s.results.count == 2)
        s.move(-1); #expect(s.selection == 0)
        s.move(5); #expect(s.selection == 1)
        s.activate()
        #expect(pb.string(forType: .string) == "prefix z")
        s.query = "zzzqqq"
        #expect(s.results.isEmpty && s.activate() == nil)
        #expect(pb.string(forType: .string) == "prefix z")
    }

    @Test func panelModelSectionsFollowContext() throws {
        let url = try tempURL("tips.json")
        let m = PanelModel(tips: TipStore(url: url), seed: 7)
        m.update(try context(["htop", "tmux", "fish", "Terminal"]))
        #expect(m.sections.map(\.pack.id) == ["htop", "tmux", "fish", "app:com.apple.Terminal"])
        let tmux = m.sections[1]
        #expect(tmux.groups.map(\.name) == ["Panes", "Windows"])
        #expect(tmux.groups[0].keys.map(\.action) == ["Split pane left/right", "Zoom pane"])
        #expect(m.sections[3].groups.map(\.name) == ["Shell"])
        let seed = m.seed
        m.update(try context(["fish", "Terminal"]))
        #expect(m.sections.map(\.pack.id) == ["fish", "app:com.apple.Terminal"])
        #expect(m.seed != seed)

        let tip = try #require(m.tipCards.first)
        m.mark(tip, .known)
        #expect(TipStore(url: url).mark(tip.id) == .known)
        #expect(!m.tipCards.isEmpty && !m.tipCards.contains(tip))
        for s in 0..<30 as Range<UInt64> {
            #expect(!m.store.pick(from: m.tipPool, count: 3, seed: s).contains(tip))
        }
        #expect(!m.showsFooter)
        m.hotkeyConflict = "ctrl+opt+k"
        #expect(m.showsFooter)
    }
}

@MainActor struct PanelModelNavigationTests {
    @Test func threeTipCardsInnermostFirst() throws {
        for seed in 0..<20 as Range<UInt64> {
            let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: seed)
            m.update(try context(["htop", "tmux", "fish", "Terminal"]))
            #expect(m.tipCards.count == 3 && Set(m.tipCards).count == 3)
            #expect(m.tipCards.first?.packID == "htop")   // htop's only key: the innermost layer leads
        }
    }

    @Test func layerSelectionCyclesAndWraps() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.update(try context(["htop", "tmux", "fish", "Terminal"]))
        let ids = m.sections.map(\.id)
        #expect(m.selectedLayer == nil)
        m.cycleLayer(1); #expect(m.selectedLayer == ids[0])
        m.cycleLayer(1); m.cycleLayer(1); m.cycleLayer(1); #expect(m.selectedLayer == ids[3])
        m.cycleLayer(1); #expect(m.selectedLayer == ids[0])
        m.cycleLayer(-1); #expect(m.selectedLayer == ids[3])
        m.selectLayer(at: 2); #expect(m.selectedLayer == ids[2] && m.sections[2].pack.id == "fish")
        // context change that drops the selected layer clears the selection
        m.update(try context(["htop", "Terminal"]))
        #expect(m.selectedLayer == nil)
        let fresh = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        fresh.cycleLayer(-1)
        #expect(fresh.selectedLayer == nil)
    }

    @Test func sectionIDsUniqueForNestedSamePack() throws {
        let p = try packs()
        let c = Context(appName: "T", bundleID: "t", layers: [
            Layer(kind: .multiplexer, name: "tmux", packID: "tmux"),
            Layer(kind: .shell, name: "fish", packID: "fish"),
            Layer(kind: .multiplexer, name: "tmux", packID: "tmux"),
        ], packs: [p["tmux"]!, p["fish"]!, p["tmux"]!], axTrusted: true)
        #expect(c.layers[0].id == c.layers[2].id)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.update(c)
        #expect(m.sections.count == 3 && Set(m.sections.map(\.id)).count == 3)
        m.selectLayer(at: 2)
        #expect(m.selectedLayer == m.sections[2].id && m.selectedLayer != m.sections[0].id)
    }
}

/// The tool in front leads the panel: its keys, then tips, then the outer layers (user feedback on yazi in Kaku).
@MainActor struct PanelLayoutTests {
    static let yazi = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs/yazi.toml")

    func yaziContext(withPack: Bool) throws -> Context {
        let p = try packs()
        let yazi = try PackLibrary.decode(Data(contentsOf: Self.yazi))
        let layers = [Layer(kind: .program, name: "yazi", packID: withPack ? "yazi" : nil),
                      Layer(kind: .shell, name: "fish", packID: "fish"), Layer(kind: .terminal, name: "Kaku", packID: terminal.id)]
        return Context(appName: "Kaku", bundleID: "fun.tw93.kaku", layers: layers,
                       packs: (withPack ? [yazi] : []) + [p["fish"]!, terminal], axTrusted: true)
    }

    func kinds(_ m: PanelModel) -> [String] {
        m.blocks.map { b -> String in
            switch b {
            case .section(let s): s.pack.id
            case .tips: "tips"
            case .noPack(let l, _): "nopack:" + l.name
            }
        }
    }

    @Test func innermostKeysComeBeforeTips() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 3)
        m.update(try yaziContext(withPack: true))
        #expect(kinds(m) == ["yazi", "tips", "fish", "app:com.apple.Terminal"])
        guard case .section(let first) = m.blocks.first else { Issue.record("first block is not a section"); return }
        #expect(first.groups.first?.keys.contains { $0.keys == "e" } == true && !m.collapsed.contains(first.id))
    }

    @Test func programWithoutPackSaysHowToAddOne() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 3)
        m.update(try yaziContext(withPack: false))
        #expect(kinds(m) == ["nopack:yazi", "tips", "fish", "app:com.apple.Terminal"])
        #expect(NoPackSection.message("yazi") == "No keys for yazi. Add a pack in ~/.config/sanketa/packs.")
    }

    /// With no keys in the innermost layer the tips lead, as before.
    @Test func tipsLeadWhenInnermostHasNoKeys() throws {
        let tipsOnly = Pack(id: "smi", name: "nvidia-smi", processes: ["nvidia-smi"], tips: [Tip(title: "Watch", snippet: "nvidia-smi -l 1", explain: "Show the GPUs every second.", tags: ["gpu"])])
        let layers = [Layer(kind: .program, name: "nvidia-smi", packID: "smi"), Layer(kind: .shell, name: "fish", packID: "fish")]
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 3)
        m.update(Context(appName: "T", bundleID: "t", layers: layers, packs: [tipsOnly, try packs()["fish"]!], axTrusted: true))
        #expect(kinds(m) == ["tips", "smi", "fish"])
    }

    /// A new tool in front scrolls the panel to the top and opens its section; a repeat poll does neither.
    @Test func layerChangeScrollsToTopAndExpands() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 3)
        m.update(try context(["fish", "Terminal"]))
        let t0 = m.scrollToken
        m.update(try context(["fish", "Terminal"]))
        #expect(m.scrollToken == t0)
        let c = try yaziContext(withPack: true)
        m.collapsed.insert(PanelModel.sectionID(0, c.layers[0]))
        m.update(c)
        #expect(m.scrollToken == t0 + 1 && m.collapsed.isEmpty)
    }
}

@MainActor struct MonitorTimerTests {
    /// `pollInterval = 0` must not spin: the poll timer runs at 0.25 s at most, with 20% tolerance for coalescing.
    @Test func pollIntervalIsClampedAndTolerant() throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        var config = Config()
        config.pollInterval = 0
        config.terminals = ["com.apple.finder"]
        let m = ContextMonitor(config: config, library: PackLibrary())
        m.activated(finder)
        let t = try #require(m.timer)
        defer { t.invalidate() }
        #expect(t.timeInterval == 0.25 && abs(t.tolerance - 0.05) < 1e-9)
    }

    /// A saved config.toml applies at once: the poll timer follows the new terminals and pollInterval.
    @Test func reloadedConfigAppliesLive() throws {
        let app = try #require(NSWorkspace.shared.frontmostApplication)
        let bid = try #require(app.bundleIdentifier)
        try #require(bid != Bundle.main.bundleIdentifier)
        var config = Config()
        config.terminals = []
        let m = ContextMonitor(config: config, library: PackLibrary())
        m.activated(app)
        #expect(m.timer == nil)
        config.terminals = [bid]; config.pollInterval = 2
        m.reload(config: config, library: PackLibrary())
        #expect(m.timer?.timeInterval == 2)
        config.pollInterval = 3
        m.reload(config: config, library: PackLibrary())
        #expect(m.timer?.timeInterval == 3)
        m.timer?.invalidate()
    }
}

@MainActor @Suite(.serialized) struct PanelFocusTests {
    func tab(_ shift: Bool) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
    }

    @Test func clicksOutsideSearchHandFocusBack() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.model.update(try context(["htop", "tmux", "fish", "Terminal"]))
        c.show()
        c.panel.makeKey()                       // as if a click had made it key
        try #require(c.panel.isKeyWindow)
        c.clickLayer(2)                         // breadcrumb "fish"
        #expect(c.model.selectedLayer == c.model.sections[2].id)
        #expect(!c.panel.isKeyWindow && c.panel.isVisible)
        c.panel.makeKey()
        c.mouseUp()                             // any other click (tip button, section header, drag)
        #expect(!c.panel.isKeyWindow && c.panel.isVisible)
        c.beginSearch(previousApp: nil)
        c.mouseUp()                             // in search mode the panel keeps focus
        #expect(c.panel.isKeyWindow)
        c.endSearch()
    }

    @Test func tabMovesBetweenFieldAndLayerList() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.model.update(try context(["htop", "tmux", "fish", "Terminal"]))
        c.beginSearch(previousApp: nil)
        let ed = try #require(c.field.currentEditor() as? NSTextView)
        ed.insertText("split", replacementRange: NSRange(location: NSNotFound, length: 0))
        ed.doCommand(by: #selector(NSResponder.insertTab(_:)))
        let ids = c.model.sections.map(\.id)
        #expect(c.model.listFocused && c.model.selectedLayer == ids[0])
        #expect(c.panel.firstResponder === c.panel && c.panel.isKeyWindow)
        #expect(c.search.query == "split")      // the search is kept while browsing layers
        c.panel.keyDown(with: tab(false))
        #expect(c.model.selectedLayer == ids[1])
        c.panel.keyDown(with: tab(true))        // ⇧Tab in search returns to the field
        #expect(!c.model.listFocused && c.field.currentEditor() != nil && c.panel.firstResponder === c.field.currentEditor())
        c.endSearch()
        #expect(!c.panel.isKeyWindow && !c.model.listFocused)
    }

    func key(_ code: Int) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code))!
    }

    /// With the layer list focused the results are hidden: ↩ must not copy one, and ↑/↓ move between sections.
    @Test func hiddenResultsIgnoreReturn() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.model.update(try context(["htop", "tmux", "fish", "Terminal"]))
        c.beginSearch(previousApp: nil)
        let ed = try #require(c.field.currentEditor() as? NSTextView)
        ed.insertText("pane", replacementRange: NSRange(location: NSNotFound, length: 0))
        try #require(!c.search.results.isEmpty)
        ed.doCommand(by: #selector(NSResponder.insertTab(_:)))
        let ids = c.model.sections.map(\.id)
        try #require(c.model.listFocused && c.model.selectedLayer == ids[0])
        c.search.pasteboard.clearContents()
        let sel = c.search.selection
        c.panel.keyDown(with: key(kReturn))
        #expect(c.search.pasteboard.string(forType: .string) == nil)
        #expect(c.searching && c.panel.isKeyWindow)
        c.panel.keyDown(with: key(kDown))
        #expect(c.model.selectedLayer == ids[1] && c.search.selection == sel)
        c.panel.keyDown(with: key(kUp))
        #expect(c.model.selectedLayer == ids[0] && c.search.selection == sel)
        c.endSearch()
    }

    @Test func translucencyLevelsSwitchGlass() throws {
        let c = try controller()
        #expect(c.glass.style == .regular && c.model.translucency == .medium)
        c.setTranslucency(.high)
        #expect(c.glass.style == .clear && c.model.translucency == .high)
        c.setTranslucency(.low)
        #expect(c.glass.style == .regular && c.model.translucency == .low)
        #expect(Theme.tintOpacity(.low) > Theme.tintOpacity(.medium) && Theme.tintOpacity(.medium) > Theme.tintOpacity(.high))
    }
}

/// A window title with a scope token puts that pack context's groups, tips and search hits first.
@MainActor struct PanelContextTests {
    static let pack = try! PackLibrary.decode(Data("""
    id = "app:org.example.ide"
    name = "IDE"
    title_scope = ' · ([a-z]+(?::[a-z0-9]+)?)$'

    [[contexts]]
    name = "notebook"
    scopes = ["notebook"]
    groups = ["Cells", "Editing"]

    [[contexts]]
    name = "terminal"
    scopes = ["terminal"]
    groups = ["Terminal"]

    [[keys]]
    keys = "⌘1"
    action = "Focus files"
    group = "Panes"

    [[keys]]
    keys = "⌘D"
    action = "Select next match"
    group = "Editing"

    [[keys]]
    keys = "⌃C"
    action = "Interrupt shell"
    group = "Terminal"

    [[keys]]
    keys = "⌘↩"
    action = "Run cell"
    group = "Cells"

    [[tips]]
    title = "Clear the shell"
    snippet = "⌘K"
    tags = ["terminal"]

    [[tips]]
    title = "Run all cells"
    snippet = "⇧⌘↩"
    tags = ["notebook"]
    """.utf8))

    func ctx(_ title: String?) -> Context {
        let l = LayerResolver.applyContexts([Layer(kind: .app, name: "IDE", packID: Self.pack.id)], packs: [Self.pack], title: title)
        return Context(appName: "IDE", bundleID: "org.example.ide", layers: l, packs: [Self.pack], axTrusted: true)
    }

    @Test func activeContextGroupsFirstOthersFolded() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(ctx("2⚙ (!) · ide — sanketa · notebook"))
        let s = try #require(m.sections.first)
        #expect(s.layer.context == "notebook" && Breadcrumb.label(s.layer) == "IDE · notebook")
        #expect(s.groups.map(\.name) == ["Editing", "Cells", "Panes", "Terminal"])
        #expect(s.groups.map(\.inContext) == [true, true, false, false])
        #expect(s.groups.map { m.isFolded(s, $0) } == [false, false, true, true])
        m.toggle(s, s.groups[2]); m.toggle(s, s.groups[0])
        #expect(s.groups.map { m.isFolded(s, $0) } == [true, false, false, true])
        #expect(s.pack.tips.first?.title == "Run all cells")
        for seed in 0..<10 as Range<UInt64> {
            let t = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: seed)
            t.update(ctx("ide — x · notebook"))
            #expect(["Select next match", "Run cell", "Run all cells"].contains(t.tipCards.first?.title ?? ""))
        }

        m.update(ctx("ide — sanketa · terminal"))
        let t = try #require(m.sections.first)
        #expect(t.groups.map(\.name) == ["Terminal", "Panes", "Editing", "Cells"])
        #expect(t.pack.tips.first?.title == "Clear the shell")
    }

    @Test func unnamedGroupNeverFolds() throws {
        var p = Self.pack
        p.keys.append(KeyEntry(keys: "⌘Q", action: "Quit"))
        let l = LayerResolver.applyContexts([Layer(kind: .app, name: "IDE", packID: p.id)], packs: [p], title: "ide · terminal")
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(Context(appName: "IDE", bundleID: "org.example.ide", layers: l, packs: [p], axTrusted: true))
        let s = try #require(m.sections.first)
        let unnamed = try #require(s.groups.first { $0.name == nil })
        #expect(!unnamed.inContext && !m.isFolded(s, unnamed))
        #expect(s.groups.filter { !$0.inContext && $0.name != nil }.allSatisfy { m.isFolded(s, $0) })
    }

    @Test func reseedDropsMarksOfGoneSections() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(ctx("ide · notebook"))
        let s = try #require(m.sections.first)
        m.toggle(s, s.groups[0]); m.toggle(s, s.groups[3]); m.toggle(s.id)
        #expect(m.collapsed.count == 2 && m.expanded.count == 1)
        m.update(ctx("ide · terminal"))       // same section: the group marks stay; the section opens again
        #expect(m.collapsed == [PanelModel.groupID(s, s.groups[0])] && m.expanded.count == 1)
        m.update(try context(["fish", "Terminal"]))           // the section is gone
        #expect(m.collapsed.isEmpty && m.expanded.isEmpty)
    }

    @Test func titleWithoutTokenKeepsTodaysOrder() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        for title in ["ide — sanketa", nil, "ide — sanketa · web"] as [String?] {
            m.update(ctx(title))
            let s = try #require(m.sections.first)
            #expect(s.layer.context == nil && Breadcrumb.label(s.layer) == "IDE")
            #expect(s.groups.map(\.name) == ["Panes", "Editing", "Terminal", "Cells"])
            #expect(s.groups.allSatisfy { $0.inContext && !m.isFolded(s, $0) })
            #expect(s.pack == Self.pack)
        }
    }

    @Test func searchPutsActiveContextFirst() throws {
        let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
        s.setSource(library: PackLibrary(packs: [:]), context: ctx("ide — x · terminal"))
        s.query = "s"
        #expect(s.results.first?.title == "Interrupt shell")
        s.setSource(context: ctx("ide — x · notebook"))
        s.query = "se"
        #expect(s.results.first?.title == "Select next match")
    }
}
