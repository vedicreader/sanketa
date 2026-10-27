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

/// Pinning, the edit choices of each row, the inputs of the suggestions and the confirm text; no window.
@MainActor @Suite struct ComboEditTests {
    let hyper = Set(Modifier.allCases)
    let aero = AeroSpaceConfig.parse("[mode.main.binding]\n" + (1...9).map { "cmd-alt-ctrl-shift-\($0) = 'workspace \($0)'" }.joined(separator: "\n")
                                     + "\ncmd-alt-ctrl-shift-left = 'move left'\nalt-ctrl-t = 'layout tiles'")
    let leela = AppKeys(layer: "Leela", pack: "leela", entries: [
        KeyEntry(keys: "Caps\u{a0}Z / ⌥⇧B", action: "Toggle file pane", group: "Panes", command: "toggle-files"),
        KeyEntry(keys: "Caps\u{a0}X", action: "Toggle tools", group: "Panes", command: "toggle-tools"),
        KeyEntry(keys: "Caps\u{a0}←", action: "Focus left", group: "Move", command: "focus-left")])
    let tmux = AppKeys(layer: "tmux", entries: [KeyEntry(keys: "Caps\u{a0}1", action: "Window 1", command: "select-window -t 1")])

    var view: ComboView { ComboView.build(mods: hyper, mode: "main", aero: aero, appName: "Kaku", apps: [leela, tmux], hyperLabel: "Caps") }
    var sources: EditSources {
        EditSources(aero: aero, apps: [leela, tmux], aeroFile: URL(fileURLWithPath: NSHomeDirectory() + "/.aerospace.toml"),
                    leelaFile: URL(fileURLWithPath: NSHomeDirectory() + "/.config/leela/keys.json"), known: { [Chord(mods: self.hyper, key: "q")] })
    }
    func model() throws -> PanelModel {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.editSources = sources
        m.showCombo(view)
        return m
    }
    func row(_ action: String) -> ComboRow { (view.aero + view.app).first { $0.action == action }! }

    @Test func pinKeepsTheComboAfterLetGo() throws {
        let m = try model()
        m.shownForCombo = true
        m.pinCombo(); m.hideCombo()
        #expect(m.combo != nil && m.comboPinned)   // pinned: let-go does not hide
        #expect(m.unpinCombo())                    // the panel was shown for the combo: the app hides it
        #expect(m.combo == nil && !m.comboPinned)
    }
    @Test func pinNeedsACombo() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        m.pinCombo()
        #expect(!m.comboPinned)
    }
    @Test func unpinEndsTheEdit() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        #expect(m.comboPinned && m.editing != nil)
        m.unpinCombo()
        #expect(m.editing == nil && m.editChoices.isEmpty)
    }
    @Test func groupRowsGiveEachChord() {
        let r = ComboRow(keys: "1 – 9", action: "Go to a workspace", chords: (1...9).map { Chord(mods: Set(Modifier.allCases), key: "\($0)") }, muted: false, clash: false, layer: nil)
        #expect(PanelModel.editTargets(r).count == 9)
    }
    @Test func aGroupRowListsItsChordsFirst() throws {
        let m = try model()
        m.clickRow(row("Go to a workspace"), aero: true)
        #expect(m.editing == nil)
        #expect(m.editChoices.count == 9)
        #expect(m.editChoices.allSatisfy { $0.source == .aerospace(mode: "main") })
        #expect(m.editChoices.first?.title == "Caps\u{a0}1 · Go to workspace 1")
        m.choose(m.editChoices[2])
        #expect(m.editing?.chord == Chord(mods: hyper, key: "3") && m.editChoices.isEmpty)
        #expect(m.editing?.file?.path == NSHomeDirectory() + "/.aerospace.toml")
    }
    @Test func aLeelaRowWithOneChordStartsTheEdit() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        #expect(m.editing?.source == .leela(action: "toggle-tools", live: "hyper+x"))
        #expect(m.editing?.suggestions.count == 3)
    }
    @Test func aLeelaClashOffersBothKeys() throws {
        let cs = PanelModel.choices(row("Focus left"), aeroColumn: false, view: view, sources: sources, hyperLabel: "Caps")
        // the pack's name, not the front app's: Leela can run in a terminal
        #expect(cs.map(\.title) == ["Change Leela's key", "Change AeroSpace's key"])
        #expect(cs.first?.source == .leela(action: "focus-left", live: "hyper+left"))
        #expect(cs.last?.source == .aerospace(mode: "main") && cs.last?.row.action == "Move the tile left")
    }
    @Test func otherAppsAreReadOnly() {
        let clash = PanelModel.choices(row("Window 1"), aeroColumn: false, view: view, sources: sources, hyperLabel: "Caps")
        #expect(clash.map(\.title) == ["Change AeroSpace's key"])
        let plain = ComboRow(keys: "W", action: "W", chords: [Chord(mods: hyper, key: "w")], command: "w", pack: "tmux")
        #expect(PanelModel.choices(plain, aeroColumn: false, view: view, sources: sources, hyperLabel: "Caps").isEmpty)
        let noAction = ComboRow(keys: "W", action: "W", chords: [Chord(mods: hyper, key: "w")], pack: "leela")
        #expect(PanelModel.choices(noAction, aeroColumn: false, view: view, sources: sources, hyperLabel: "Caps").isEmpty)
    }
    @Test func noAeroSpaceFileMeansNoAeroSpaceChoice() {
        var s = sources; s.aeroFile = nil
        #expect(PanelModel.choices(row("Window 1"), aeroColumn: false, view: view, sources: s, hyperLabel: "Caps").isEmpty)
        #expect(PanelModel.choices(row("Go to a workspace"), aeroColumn: true, view: view, sources: s, hyperLabel: "Caps").isEmpty)
    }
    @Test func liveValueHasEveryChordOfTheAction() {
        // the row shows only the Caps chord; the value that Leela reads also has ⌥⇧B
        #expect(PanelModel.live(row("Toggle file pane"), apps: [leela], hyperLabel: "Caps") == "hyper+z alt+shift+b")
        let lone = ComboRow(keys: "Y", action: "Y", chords: [Chord(mods: hyper, key: "y")], command: "gone", pack: "leela")
        #expect(PanelModel.live(lone, apps: [leela], hyperLabel: "Caps") == "hyper+y")
    }
    @Test func suggestionsAvoidEveryUsedChordAndStayNearPartners() {
        let x = Chord(mods: hyper, key: "x"), z = Chord(mods: hyper, key: "z")
        let i = PanelModel.suggestInputs(row: row("Toggle tools"), chord: x, source: .leela(action: "toggle-tools", live: "hyper+x"), view: view, sources: sources)
        #expect(i.partners == [z])
        #expect(i.used.contains(x))   // the chord now is never offered
        #expect(i.used.isSuperset(of: [z, Chord(mods: [.opt, .shift], key: "b"), Chord(mods: hyper, key: "5"), Chord(mods: [.ctrl, .opt], key: "t")]))
        #expect(!i.used.contains(Chord(mods: hyper, key: "q")))   // every pack is checked only for AeroSpace keys
        let three = Chord(mods: hyper, key: "3")
        let a = PanelModel.suggestInputs(row: row("Go to a workspace"), chord: three, source: .aerospace(mode: "main"), view: view, sources: sources)
        #expect(a.used.contains(Chord(mods: hyper, key: "q")) && a.used.contains(three))
        #expect(a.partners.count == 8 && !a.partners.contains(three))
    }
    @Test func suggestionsNeverOfferTheChordNow() throws {
        let m = try model()
        for (r, aero) in view.aero.map({ ($0, true) }) + view.app.map({ ($0, false) }) {
            for c in PanelModel.choices(r, aeroColumn: aero, view: view, sources: sources, hyperLabel: "Caps") {
                m.choose(c)
                #expect(m.editing?.suggestions.isEmpty == false)
                #expect(m.editing?.suggestions.contains { $0.chord == c.chord } == false, "\(c.title)")
            }
        }
    }
    @Test func pickRefusesTheChordNow() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        m.editing?.recording = true
        #expect(!m.pick(Chord(mods: hyper, key: "x")))
        #expect(m.editing?.new == nil && m.editing?.recording == true)
        #expect(m.editing?.warning == "Caps\u{a0}X is the key now. Press a different chord.")
        #expect(m.pick(Chord(mods: hyper, key: "y")) && m.editing?.warning == nil)
    }
    @Test func aLeelaKeyThatLeelaCannotReadIsRefused() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        #expect(!m.pick(Chord(mods: hyper, key: "f13")) && m.editing?.new == nil)
        #expect(m.editing?.warning == "Leela cannot use Caps\u{a0}F13. Press a different chord.")
        #expect(m.pick(Chord(mods: hyper, key: "f12")))
    }
    @Test func aPinnedViewDoesNotRefreshUnderAnOpenEdit() throws {
        let m = try model()
        #expect(m.pinnedRefreshable == false)
        m.clickRow(row("Toggle tools"), aero: false)
        #expect(m.editing != nil && m.pinnedRefreshable == false)
        m.cancelEdit()
        #expect(m.pinnedRefreshable == true)
    }
    @Test func aChordNeedsAModifierOutsideAnAeroSpaceMode() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        #expect(!m.pick(Chord(mods: [], key: "y")))
        #expect(m.editing?.warning == "Press a chord with one or more modifier keys.")
        let modes = AeroSpaceConfig.parse("[mode.resize.binding]\nminus = 'resize smart -50'\nesc = 'mode main'")
        let r = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        r.editSources = EditSources(aero: modes, aeroFile: URL(fileURLWithPath: "/a.toml"))
        r.showCombo(ComboView.build(mods: [], mode: "resize", aero: modes, appName: "x", apps: [], hyperLabel: "Caps"))
        r.clickRow(r.combo!.aero[0], aero: true)
        #expect(r.editing?.source == .aerospace(mode: "resize"))
        #expect(r.pick(Chord(mods: [], key: "y")))
    }
    @Test func aChordInUseShowsItsOwner() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        m.pick(Chord(mods: hyper, key: "z"))   // another Leela key: the same file
        #expect(m.editing?.inUse == "Caps\u{a0}Z is in use by Leela." && m.editing?.blocked == true)
        m.pick(Chord(mods: hyper, key: "5"))   // AeroSpace gets it first, but keys.json can hold it
        #expect(m.editing?.inUse == "Caps\u{a0}5 is in use by AeroSpace." && m.editing?.blocked == false)
        m.pick(Chord(mods: hyper, key: "y"))
        #expect(m.editing?.inUse == nil && m.editing?.blocked == false)

        m.clickRow(row("Go to a workspace"), aero: true); m.choose(m.editChoices[2])
        m.pick(Chord(mods: [.ctrl, .opt], key: "t"))   // the same AeroSpace mode
        #expect(m.editing?.inUse == "⌃⌥T is in use by AeroSpace." && m.editing?.blocked == true)
        m.pick(Chord(mods: hyper, key: "x"))
        #expect(m.editing?.inUse == "Caps\u{a0}X is in use by Leela." && m.editing?.blocked == false)
        m.pick(Chord(mods: hyper, key: "q"))   // only a pack that is not in front has it
        #expect(m.editing?.inUse == "Caps\u{a0}Q is in use." && m.editing?.blocked == false)
    }
    @Test func theUndoToastStaysLonger() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        var t = Date()
        m.now = { t }
        m.showSaveToast("Changed.", action: ToastAction(title: "Undo") {})
        t += PanelModel.saveToastSeconds + 1; m.expireToast()
        #expect(m.toast == "Changed.")
        t += 10; m.expireToast()
        #expect(m.toast == nil)
    }
    @Test func confirmTextNamesTheChangeAndTheFile() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        #expect(m.confirmText == nil)
        m.pick(Chord(mods: hyper, key: "y"))
        #expect(m.confirmText == "Change Toggle tools: Caps\u{a0}X → Caps\u{a0}Y in ~/.config/leela/keys.json?")
        #expect(PanelModel.fileLabel(URL(fileURLWithPath: "/etc/x.toml")) == "/etc/x.toml")
    }
    @Test func pickStopsTheRecordingAndCancelEndsTheEdit() throws {
        let m = try model()
        m.clickRow(row("Toggle tools"), aero: false)
        m.editing?.recording = true
        m.pick(Chord(mods: hyper, key: "y"))
        #expect(m.editing?.recording == false && m.editing?.new == Chord(mods: hyper, key: "y"))
        m.cancelEdit()
        #expect(m.editing == nil && m.comboPinned)
    }
    @Test func aPressedKeyBecomesAChord() {
        #expect(PanelModel.chord(keyCode: 16, flags: [.control, .option, .shift, .command, .capsLock]) == Chord(mods: hyper, key: "y"))
        #expect(PanelModel.chord(keyCode: 123, flags: [.option, .function, .numericPad]) == Chord(mods: [.opt], key: "left"))
        #expect(PanelModel.chord(keyCode: 36, flags: .command) == Chord(mods: [.cmd], key: "enter"))
        #expect(PanelModel.chord(keyCode: 56, flags: .shift) == nil)   // a modifier key alone
    }
    @Test func aToastCanHaveAnAction() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
        var ran = false
        m.showSaveToast("Changed.", action: ToastAction(title: "Undo") { ran = true })
        #expect(m.toast == "Changed." && m.toastAction?.title == "Undo")
        m.toastAction?.run()
        #expect(ran)
        m.showToast(PanelModel.copied)
        #expect(m.toastAction == nil)
    }
}
