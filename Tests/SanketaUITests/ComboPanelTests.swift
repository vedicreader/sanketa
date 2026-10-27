import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

@MainActor @Suite struct ComboPanelTests {
    @Test func showAndHideCombo() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        let v = ComboView(mods: Set(Modifier.allCases), mode: "main", aero: [], also: [], appName: "leela", app: [], free: ["O"])
        m.showCombo(v)
        #expect(m.combo == v)
        m.hideCombo()
        #expect(m.combo == nil)
    }

    @Test func comboPanelSaysWhenTheAppHasNoKeys() {
        #expect(ComboPanel.emptyAppLine(appName: "Kaku", combo: "Caps") == "No Caps keys")
        #expect(ComboPanel.freeLine(["O", "Y"], combo: "Caps") == "Free Caps keys: O Y")
    }
}
