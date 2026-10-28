import AppKit
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// Fake data for the combo panel scenarios of `RenderTests`: no real AeroSpace or Leela file is read.
extension RenderTests {
    static let hyper = "Caps\u{a0}"
    static let aeroText = """
    [mode.main.binding]
    cmd-alt-ctrl-shift-left = 'move left'
    cmd-alt-ctrl-shift-right = 'move right'
    cmd-alt-ctrl-shift-up = 'focus up'
    cmd-alt-ctrl-shift-3 = 'move-node-to-workspace --focus-follows-window 3'
    cmd-alt-ctrl-shift-4 = 'workspace 4'
    cmd-alt-ctrl-shift-f = 'fullscreen'
    cmd-alt-ctrl-shift-w = 'move-node-to-workspace --wrap-around next'
    cmd-alt-ctrl-shift-tab = 'workspace-back-and-forth'
    cmd-alt-ctrl-shift-e = ['balance-sizes', 'mode main']
    cmd-alt-ctrl-shift-r = 'mode resize'
    [mode.resize.binding]
    h = 'resize width -50'
    j = 'resize height +50'
    k = 'resize height -50'
    l = 'resize width +50'
    minus = 'resize smart -50'
    equal = 'resize smart +50'
    b = ['balance-sizes', 'mode main']
    enter = 'mode main'
    esc = 'mode main'
    """

    /// A real-world shape: arrows, H J K L and 1 to 9 of one command each become one row with a wide key label.
    static let groupedAeroText: String = {
        let p = "cmd-alt-ctrl-shift-"
        var l = ["[mode.main.binding]"]
        l += ["left", "down", "up", "right"].map { "\(p)\($0) = 'move \($0)'" }
        l += zip(["h", "j", "k", "l"], ["left", "down", "up", "right"]).map { "\(p)\($0) = 'focus \($1)'" }
        l += (1...9).map { "\(p)\($0) = 'workspace \($0)'" }
        l += ["\(p)space = 'layout floating tiling'", "\(p)tab = 'workspace-back-and-forth'", "\(p)f = 'fullscreen'",
              "\(p)w = 'move-node-to-workspace --wrap-around --focus-follows-window next'",
              "\(p)minus = 'resize smart -50'", "\(p)equal = 'resize smart +50'"]
        return l.joined(separator: "\n")
    }()

    static func leelaKeys(clash: Bool) -> [AppKeys] {
        func e(_ k: String, _ a: String) -> KeyEntry { KeyEntry(keys: hyper + k, action: a, command: a) }
        let notebook = [e("Z", "Undo the last change"), e("B", "Toggle the sidebar"), e("T", "Open a new tab"), e("S", "Save the notebook"),
                        e("N", "Add a cell below"), e("O", "Open a folder"), e("P", "Run all the cells")]
        let panes = [e("K", "Focus the next pane"), e("J", "Focus the last pane"), e("Y", "Copy the cell link"),
                     e("G", "Go to a line"), e("M", "Merge with the cell below")]
        var all = notebook + panes
        if clash { all[2] = e("←", "Previous tab"); all[4] = e("F", "Toggle the full-width view") }
        return [AppKeys(layer: "Notebook", entries: Array(all[..<7])), AppKeys(layer: "Panes", entries: Array(all[7...]))]
    }

    static func comboModel(_ m: PanelModel, clash: Bool, mode: String = "main", pin: Bool = false, grouped: Bool = false, taken: Bool = false) {
        let aero = AeroSpaceConfig.parse(grouped ? groupedAeroText : aeroText), apps = leelaKeys(clash: clash)
        let mods = Set(Modifier.allCases)
        let v = ComboView.build(mods: mods, mode: mode, aero: aero, appName: "Leela", apps: apps, hyperLabel: "Caps")
        let tmp = FileManager.default.temporaryDirectory
        m.editSources = EditSources(aero: aero, apps: apps, aeroFile: tmp.appendingPathComponent("fake-aerospace.toml"),
                                    leelaFile: tmp.appendingPathComponent("fake-keys.json"), sanketaFile: tmp.appendingPathComponent("fake-config.toml"),
                                    system: { KeySuggest.systemChords })
        m.hotkey = "ctrl+opt+k"
        if taken { m.hotkeyConflict = "ctrl+opt+k" }
        m.showCombo(v, hyperLabel: "Caps")
        if pin { m.pinCombo() }
    }

    /// One modifier held alone, as the app builds it: the keys of the front sections for `mods`, and no AeroSpace file.
    static func singleModel(_ m: PanelModel, mods: Set<Modifier>) {
        m.showCombo(ComboView.build(mods: mods, mode: "main", aero: nil, appName: "Kaku", apps: PanelModel.comboApps(m.sections), hyperLabel: "Caps"),
                    hyperLabel: "Caps", hasAero: false)
    }

    /// The held view is narrow (the app's keys only); the pinned view is wide.
    static func comboScenarios(_ leela: Context) -> [Scenario] {
        let wide = Theme.comboSize
        return [Scenario(name: "combo-held", context: leela) { comboModel($0, clash: true) },
                Scenario(name: "combo-held-caps", context: leela) { comboModel($0, clash: false) },
                Scenario(name: "combo-pinned", context: leela, setup: { comboModel($0, clash: true, pin: true) }, size: wide),
                Scenario(name: "combo-pinned-sanketa", context: leela, setup: { comboModel($0, clash: false, pin: true, grouped: true, taken: true) },
                         size: CGSize(width: wide.width, height: 640)),
                Scenario(name: "combo-pinned-tall", context: leela, setup: { comboModel($0, clash: true, pin: true) }, size: CGSize(width: wide.width, height: 900)),
                Scenario(name: "combo-edit", context: leela, setup: { m in
                    comboModel(m, clash: false, pin: true)
                    if let r = m.combo?.aero.first(where: { $0.action == "Move the tile left" }) { m.clickRow(r, aero: true) }
                }, size: wide),
                Scenario(name: "combo-choose", context: leela, setup: { m in
                    comboModel(m, clash: true, pin: true)
                    if let r = m.combo?.app.first(where: \.clash) { m.clickRow(r, aero: false) }
                }, size: wide),
                Scenario(name: "combo-edit-search", context: leela, setup: { m in
                    comboModel(m, clash: false, pin: true, taken: true)
                    if let r = m.sanketaRows().first { m.clickRow(r, aero: false) }
                }, size: wide)]
    }

    /// The AeroSpace bar: its name, the combo view it shows, and the width of the screen (the bar wraps at 80 % of it).
    struct BarScenario {
        var name: String
        var view: ComboView
        var screen: CGFloat = 1440
    }

    static func barScenarios() -> [BarScenario] {
        let hyper = Set(Modifier.allCases)
        func view(_ text: String, mods: Set<Modifier> = hyper, mode: String = "main") -> ComboView {
            ComboView.build(mods: mods, mode: mode, aero: .parse(text), appName: "Leela", apps: [], hyperLabel: "Caps")
        }
        return [BarScenario(name: "bar-grouped", view: view(groupedAeroText)),
                BarScenario(name: "bar-grouped-wrap", view: view(groupedAeroText), screen: 760),
                BarScenario(name: "bar-caps", view: view(aeroText)),
                BarScenario(name: "bar-resize", view: view(aeroText, mods: [], mode: "resize"))]
    }
}

/// The panel's own hosting view, as a click pins the held view: the same model calls as the click, and a layout at each
/// resize, as a visible panel does in `setFrame`. The PNG shows what the user sees after one click.
extension RenderTests {
    @Test func drawHeldThenPin() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lib = PackLibrary.load(bundled: bundledPacks, user: nil)
        LeelaKeymap.apply(to: &lib, keysJSON: nil, hyperLabel: "Caps")
        let leela = Self.scenarios(lib).first { $0.name == "combo-held" }!.context
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 7)
        m.update(leela)
        let search = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-shots-\(UUID().uuidString)")))
        let pc = PanelController(model: m, search: search, hotkeyLabel: "⌃⌥K")
        defer { pc.panel.orderOut(nil) }
        pc.panel.appearance = NSAppearance(named: .darkAqua)
        pc.panel.setFrame(NSRect(origin: .zero, size: CGSize(width: Theme.panelSize.width, height: 560)), display: false)
        let host = try #require(pc.glass.contentView)
        func settle() { for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
        let o = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: pc.panel, queue: nil) { _ in
            MainActor.assumeIsolated { host.layoutSubtreeIfNeeded() }
        }
        defer { NotificationCenter.default.removeObserver(o) }
        Self.comboModel(m, clash: false)   // the held view
        settle()
        try write(host, name: "held-then-pin-0-held")
        m.pinCombo()   // one click in the panel
        settle()
        try write(host, name: "held-then-pin-1-pinned")
        m.hideCombo()   // the let-go of Caps
        settle()
        try write(host, name: "held-then-pin-2-let-go")
    }

    func write(_ v: NSView, name: String) throws {
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { v.cacheDisplay(in: v.bounds, to: rep) }
        let img = try Self.compose(try #require(rep.cgImage), level: .medium, scale: rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1, size: v.bounds.size)
        let f = Self.out.appendingPathComponent("\(name).png")
        try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: f)
        print("render output: \(f.path)")
    }
}
