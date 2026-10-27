import Foundation
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

    static func comboModel(_ m: PanelModel, clash: Bool, mode: String = "main", pin: Bool = false) {
        let aero = AeroSpaceConfig.parse(aeroText), apps = leelaKeys(clash: clash)
        let mods = Set(Modifier.allCases)
        let v = ComboView.build(mods: mods, mode: mode, aero: aero, appName: "Leela", apps: apps, hyperLabel: "Caps")
        let tmp = FileManager.default.temporaryDirectory
        m.editSources = EditSources(aero: aero, apps: apps, aeroFile: tmp.appendingPathComponent("fake-aerospace.toml"),
                                    leelaFile: tmp.appendingPathComponent("fake-keys.json"))
        m.showCombo(v, hyperLabel: "Caps")
        if pin { m.pinCombo() }
    }

    static func comboScenarios(_ leela: Context) -> [Scenario] {
        scenes(leela).map { var s = $0; if s.size == Theme.panelSize { s.size = Theme.comboSize }; return s }
    }

    private static func scenes(_ leela: Context) -> [Scenario] {
        [Scenario(name: "combo-caps", context: leela) { comboModel($0, clash: false) },
         Scenario(name: "combo-clash", context: leela) { comboModel($0, clash: true) },
         Scenario(name: "combo-clash-tall", context: leela, setup: { comboModel($0, clash: true) }, size: CGSize(width: Theme.comboSize.width, height: 900)),
         Scenario(name: "combo-pinned", context: leela) { comboModel($0, clash: true, pin: true) },
         Scenario(name: "combo-edit", context: leela) { m in
             comboModel(m, clash: false, pin: true)
             if let r = m.combo?.aero.first(where: { $0.action == "Move the tile left" }) { m.clickRow(r, aero: true) }
         },
         Scenario(name: "combo-choose", context: leela) { m in
             comboModel(m, clash: true, pin: true)
             if let r = m.combo?.app.first(where: \.clash) { m.clickRow(r, aero: false) }
         },
         Scenario(name: "combo-aero-resize", context: leela) { comboModel($0, clash: false, mode: "resize") }]
    }
}
