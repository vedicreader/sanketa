import Foundation
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

@MainActor @Suite struct ComboSearchTests {
    @Test func hidingTheComboTellsIfThePanelWasShownForIt() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        let v = ComboView(mods: Set(Modifier.allCases), mode: "main", aero: [], also: [], appName: "leela", app: [], free: [])
        m.shownForCombo = true; m.showCombo(v)
        #expect(m.hideCombo())
        #expect(m.combo == nil && !m.shownForCombo)
        #expect(!m.hideCombo())
    }

    @Test func aeroSpaceReadErrorShowsInTheFooter() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.aeroError = PackLoadError(file: "/x/.aerospace.toml", message: "Could not read this file.")
        #expect(m.showsFooter)
        #expect(m.errorLines.first?.text == ".aerospace.toml: Could not read this file.")
    }

    @Test func aeroSpaceUrlsListBothPlaces() {
        let home = URL(fileURLWithPath: "/h")
        #expect(AeroSpaceConfig.urls(env: [:], home: home).map(\.path) == ["/h/.aerospace.toml", "/h/.config/aerospace/aerospace.toml"])
    }
}
