import AppKit
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// The panel width follows the state: the combo view is wide, all else is narrow. No test shows the panel.
@MainActor @Suite struct PanelWidthTests {
    let hyper = ComboView(mods: Set(Modifier.allCases), mode: "main", aero: [], also: [], appName: "Kaku", app: [], free: [])
    let mode = ComboView(mods: [], mode: "service", aero: [], also: [], appName: "Kaku", app: [], free: [])

    func setWidth(_ pc: PanelController, _ w: CGFloat) {
        var f = pc.panel.frame; f.size.width = w
        pc.panel.setFrame(f, display: false)
    }

    @Test func comboShowsWideAndHidesNarrow() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
        pc.model.hideCombo()
        #expect(pc.panel.frame.width == Theme.panelSize.width)
    }

    /// Something outside the controller (a restored autosave frame, a window manager, a drag) makes the panel narrow
    /// while the combo view stays. The next combo view must be wide again.
    @Test func aNewComboViewMakesANarrowPanelWideAgain() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        setWidth(pc, Theme.panelSize.width)
        pc.model.showCombo(mode)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
    }

    /// A resize from outside cannot make the combo view narrow, or the list view wide.
    @Test func theWidthComesBackAfterAResize() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        setWidth(pc, Theme.panelSize.width)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
        pc.model.hideCombo()
        setWidth(pc, Theme.comboSize.width)
        #expect(pc.panel.frame.width == Theme.panelSize.width)
    }

    /// The height stays as the user sets it.
    @Test func aResizeKeepsTheHeight() throws {
        let pc = try controller()
        pc.model.showCombo(hyper)
        var f = pc.panel.frame; f.size.height = 700
        pc.panel.setFrame(f, display: false)
        #expect(pc.panel.frame.height == 700)
        #expect(pc.panel.frame.width == Theme.comboSize.width)
    }
}
