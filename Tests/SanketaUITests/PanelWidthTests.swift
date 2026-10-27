import AppKit
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// The panel width follows the state: only the pinned combo view is wide; a held combo and all else are narrow. No test
/// shows the panel.
@MainActor @Suite struct PanelWidthTests {
    let hyper = ComboView(mods: Set(Modifier.allCases), mode: "main", aero: [], also: [], appName: "Kaku", app: [], free: [])
    let mode = ComboView(mods: [], mode: "service", aero: [], also: [], appName: "Kaku", app: [], free: [])

    func setWidth(_ pc: PanelController, _ w: CGFloat) {
        var f = pc.panel.frame; f.size.width = w
        pc.panel.setFrame(f, display: false)
    }

    @Test func aHeldComboStaysNarrowAndAPinWidens() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        #expect(pc.panel.frame.width == Theme.panelSize.width)
        pc.model.pinCombo()
        #expect(pc.panel.frame.width == Theme.comboSize.width)
        pc.model.unpinCombo()
        #expect(pc.panel.frame.width == Theme.panelSize.width)
    }

    /// Something outside the controller (a restored autosave frame, a window manager, a drag) makes the panel narrow
    /// while the view stays pinned. The next combo view must be wide again.
    @Test func aNewComboViewMakesANarrowPinnedPanelWideAgain() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        pc.model.pinCombo()
        setWidth(pc, Theme.panelSize.width)
        pc.model.showCombo(mode)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
    }

    /// A resize from outside cannot make the pinned view narrow, or the held view and the list view wide.
    @Test func theWidthComesBackAfterAResize() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        setWidth(pc, Theme.comboSize.width)
        #expect(pc.panel.frame.width == Theme.panelSize.width)
        pc.model.pinCombo()
        setWidth(pc, Theme.panelSize.width)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
        pc.model.unpinCombo()
        setWidth(pc, Theme.comboSize.width)
        #expect(pc.panel.frame.width == Theme.panelSize.width)
    }

    /// The height stays as the user sets it.
    @Test func aResizeKeepsTheHeight() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        pc.model.pinCombo()
        var f = pc.panel.frame; f.size.height = 700
        pc.panel.setFrame(f, display: false)
        #expect(pc.panel.frame.height == 700)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
    }
}

/// The held view has only the app's column and "Click to keep this open"; the pinned view has both columns, the free
/// keys and the close line. The AeroSpace bar never takes the focus or the mouse, and hides when the view is pinned.
@MainActor @Suite struct HeldAndPinnedTests {
    @Test func theHeldViewShowsOnlyTheAppColumn() {
        #expect(!ComboPanel.showsAeroColumn(pinned: false, hasAero: true))
        #expect(!ComboPanel.showsFree(pinned: false))
        #expect(ComboPanel.footer(pinned: false) == "Click to keep this open")
    }

    @Test func thePinnedViewShowsBothColumns() {
        #expect(ComboPanel.showsAeroColumn(pinned: true, hasAero: true))
        #expect(!ComboPanel.showsAeroColumn(pinned: true, hasAero: false))
        #expect(ComboPanel.showsFree(pinned: true))
        #expect(ComboPanel.footer(pinned: true) == "Esc or a click outside closes this.")
    }

    func bar() throws -> (AeroBarController, PanelModel) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        return (AeroBarController(model: m), m)
    }

    @Test func theBarIsClickThroughAndNeverKey() throws {
        let (b, _) = try bar()
        #expect(b.panel.ignoresMouseEvents)
        #expect(!b.panel.canBecomeKey && !b.panel.canBecomeMain)
        #expect(b.panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        #expect(b.panel.level == .floating)
        #expect(b.panel.styleMask.contains(.nonactivatingPanel) && b.panel.styleMask.contains(.borderless))
    }

    @Test func theBarSitsAtTheTopCenterUnderTheMenuBar() {
        let f = AeroBarController.frame(size: CGSize(width: 400, height: 30), visible: NSRect(x: 0, y: 0, width: 1440, height: 875))
        #expect(f == NSRect(x: 520, y: 875 - AeroBarController.gap - 30, width: 400, height: 30))
    }

    @Test func theBarFollowsTheTranslucencyAndAPinHidesIt() throws {
        let (b, m) = try bar()
        m.translucency = .high
        #expect(b.glass.style == .clear)
        m.translucency = .low
        #expect(b.glass.style == .regular)
        m.showCombo(ComboView(mods: Set(Modifier.allCases), mode: "main", aero: [], also: [], appName: "x", app: [], free: []))
        m.pinCombo()
        b.show(AeroBar(view: ComboView.build(mods: Set(Modifier.allCases), mode: "main", aero: .parse("[mode.main.binding]\ncmd-alt-ctrl-shift-f = 'fullscreen'"),
                                             appName: "x", apps: [], hyperLabel: "Caps")))
        #expect(b.bar == nil && !b.isVisible)   // a pinned view: the bar stays hidden
    }
}

/// Sanketa's own Search row: in the pinned view always, in the held view when its chord uses the held keys; a click opens
/// the change-key step with left-hand two-key chords.
@MainActor @Suite struct SanketaRowTests {
    let hyper = Set(Modifier.allCases)

    func model(_ mods: Set<Modifier>, hotkey: String = "ctrl+opt+k", file: URL? = URL(fileURLWithPath: "/tmp/sanketa-test-config.toml")) throws -> PanelModel {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        let aero = AeroSpaceConfig.parse("[mode.main.binding]\nalt-shift-a = 'fullscreen'")
        m.editSources = EditSources(aero: aero, aeroFile: URL(fileURLWithPath: "/tmp/fake-aerospace.toml"), sanketaFile: file, system: { KeySuggest.systemChords })
        m.hotkey = hotkey
        m.showCombo(ComboView.build(mods: mods, mode: "main", aero: aero, appName: "Kaku", apps: [], hyperLabel: "Caps"))
        return m
    }

    @Test func theRowShowsWhenPinnedOrWhenItsModifiersAreHeld() throws {
        let held = try model(hyper)
        #expect(held.sanketaRows().isEmpty)
        held.pinCombo()
        #expect(held.sanketaRows().map(\.keys) == ["⌃⌥K"])
        #expect(held.sanketaRows().first?.action == "Search")
        #expect(try model([.ctrl, .opt]).sanketaRows().map(\.keys) == ["⌃⌥K"])
    }

    @Test func aClickOpensTheChangeStepWithFreeLeftHandChords() throws {
        let m = try model(hyper)
        m.pinCombo()
        m.hotkeyConflict = "ctrl+opt+k"
        let r = try #require(m.sanketaRows().first)
        #expect(m.canEdit(r, aero: false))
        m.clickRow(r, aero: false)
        let e = try #require(m.editing)
        #expect(e.source == .sanketa && e.chord == Chord(mods: [.ctrl, .opt], key: "k"))
        #expect(e.file?.path == "/tmp/sanketa-test-config.toml")
        #expect(e.note == "macOS or another app uses ⌃⌥K now.")
        let used = Set([Chord(mods: [.ctrl, .opt], key: "k"), Chord(mods: [.opt, .shift], key: "a")]).union(KeySuggest.systemChords)
        #expect(!e.suggestions.isEmpty && e.suggestions.allSatisfy { !used.contains($0.chord) && $0.chord.mods.count == 2 })
        #expect(e.suggestions.first?.chord == Chord(mods: [.opt, .shift], key: "space"))
        #expect(m.pick(e.suggestions[0].chord))
        #expect(m.confirmText == "Change Search: ⌃⌥K → ⌥⇧space in /tmp/sanketa-test-config.toml?")
    }

    @Test func aChordThatSanketaCannotRegisterIsRefused() throws {
        let m = try model(hyper)
        m.pinCombo()
        m.clickRow(try #require(m.sanketaRows().first), aero: false)
        #expect(!m.pick(Chord(mods: [.ctrl, .opt], key: "left")))
        #expect(m.editing?.warning == "Sanketa cannot use ⌃⌥← as a hotkey. Press a different chord.")
        #expect(m.pick(Chord(mods: [.opt, .shift], key: "a")))
        #expect(m.editing?.inUse == "⌥⇧A is in use by AeroSpace." && m.editing?.blocked == false)
    }

    @Test func noConfigPathMeansNoChange() throws {
        let m = try model(hyper, file: nil)
        m.pinCombo()
        #expect(!m.canEdit(try #require(m.sanketaRows().first), aero: false))
    }
}

/// The bar of a real Caps config has items, and it measures more than zero (a zero size kept the bar from showing).
@MainActor @Suite struct AeroBarShowTests {
    let hyper = Set(Modifier.allCases)
    static let toml = """
    [mode.main.binding]
    cmd-alt-ctrl-shift-left = 'move left'
    cmd-alt-ctrl-shift-down = 'move down'
    cmd-alt-ctrl-shift-up = 'move up'
    cmd-alt-ctrl-shift-right = 'move right'
    cmd-alt-ctrl-shift-h = 'focus left'
    cmd-alt-ctrl-shift-j = 'focus down'
    cmd-alt-ctrl-shift-k = 'focus up'
    cmd-alt-ctrl-shift-l = 'focus right'
    cmd-alt-ctrl-shift-1 = 'workspace 1'
    cmd-alt-ctrl-shift-2 = 'workspace 2'
    cmd-alt-ctrl-shift-tab = 'workspace-back-and-forth'
    cmd-alt-ctrl-shift-s = 'workspace next'
    cmd-alt-ctrl-shift-f = 'fullscreen'
    cmd-alt-ctrl-shift-t = 'layout floating tiling'
    cmd-alt-ctrl-shift-r = 'mode resize'
    [mode.resize.binding]
    esc = 'mode main'
    """

    func view() -> ComboView {
        ComboView.build(mods: hyper, mode: "main", aero: .parse(Self.toml), appName: "Kaku", apps: [], hyperLabel: "Caps")
    }

    @Test func aHyperConfigGivesABar() throws {
        let bar = try #require(AeroBar(view: view()))
        #expect(bar.items.count > 3)
    }

    @Test func theBarMeasuresMoreThanZero() throws {
        _ = NSApplication.shared
        let b = AeroBarController(model: PanelModel(tips: TipStore(url: try tempURL("tips.json"))))
        let bar = try #require(AeroBar(view: view()))
        b.host.rootView = AeroBarView(bar: bar, maxWidth: 1100, translucency: .medium)
        let s = AeroBarController.fitting(b.host)
        #expect(s.width > 100 && s.height > 10)
    }
}
