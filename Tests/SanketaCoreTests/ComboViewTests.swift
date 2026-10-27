import Testing
@testable import SanketaCore

@Suite struct ComboViewTests {
    let aero = AeroSpaceConfig.parse(aeroSample)
    let hyper = Set(Modifier.allCases)

    func build(_ toml: String, mods: Set<Modifier>? = nil, apps: [AppKeys] = []) -> ComboView {
        ComboView.build(mods: mods ?? hyper, mode: "main", aero: .parse(toml), appName: "x", apps: apps, hyperLabel: "Caps")
    }

    @Test func aerospaceColumnGroupsAndOrders() {
        let v = ComboView.build(mods: hyper, mode: "main", aero: aero, appName: "leela", apps: [], hyperLabel: "Caps")
        #expect(v.aero.first?.action == "Move the tile left")
        #expect(v.aero.last?.muted == true)   // balance-sizes is a resize command
        #expect(v.also.contains { $0.hasPrefix("Send to a workspace also:") })
    }
    @Test func alsoListsOtherCombosWithStayOrFollow() {
        let v = ComboView.build(mods: hyper, mode: "main", aero: aero, appName: "leela", apps: [], hyperLabel: "Caps")
        #expect(v.also == ["Send to a workspace also: ⌃⌥⇧ 3 (stay), ⌃⌥ 3 (follow)"])
    }
    @Test func appColumnMarksClashes() {
        let leela = AppKeys(layer: "leela", entries: [
            KeyEntry(keys: "Caps\u{a0}Z / ⌥⇧B", action: "Toggle file pane"),
            KeyEntry(keys: "Caps\u{a0}←", action: "Toggle bottom tools")])
        let v = ComboView.build(mods: hyper, mode: "main", aero: aero, appName: "leela", apps: [leela], hyperLabel: "Caps")
        #expect(v.app.map(\.action) == ["Toggle file pane", "Toggle bottom tools"])
        #expect(v.app.last?.clash == true && v.app.first?.clash == false)
        #expect(v.app.first?.layer == nil)
        #expect(!v.free.contains("Z") && !v.free.contains("R") && v.free.contains("O"))
    }
    @Test func otherModeShowsAllItsKeys() {
        let v = ComboView.build(mods: [], mode: "resize", aero: aero, appName: "Kaku", apps: [], hyperLabel: "Caps")
        #expect(v.aero.map(\.keys) == ["-", "esc"])
    }
    @Test func fourArrowsBecomeOneRow() {
        let v = build("""
        [mode.main.binding]
        cmd-alt-ctrl-shift-left = 'move left'
        cmd-alt-ctrl-shift-down = 'move down'
        cmd-alt-ctrl-shift-up = 'move up'
        cmd-alt-ctrl-shift-right = 'move right'
        """)
        #expect(v.aero.map(\.keys) == ["← ↑ ↓ →"])
        #expect(v.aero.first?.action == "Move the tile")
        #expect(v.aero.first?.chords.count == 4)
    }
    @Test func hjklFocusBecomesOneRow() {
        let v = build("""
        [mode.main.binding]
        cmd-alt-ctrl-shift-h = 'focus left'
        cmd-alt-ctrl-shift-j = 'focus down'
        cmd-alt-ctrl-shift-k = 'focus up'
        cmd-alt-ctrl-shift-l = 'focus right'
        """)
        #expect(v.aero.map(\.keys) == ["H J K L"])
        #expect(v.aero.first?.action == "Focus")
    }
    @Test func nineWorkspacesBecomeOneRow() {
        let toml = "[mode.main.binding]\n" + (1...9).map { "cmd-alt-ctrl-shift-\($0) = 'workspace \($0)'" }.joined(separator: "\n")
        let v = build(toml)
        #expect(v.aero.map(\.keys) == ["1 – 9"])
        #expect(v.aero.first?.action == "Go to a workspace")
        #expect(v.aero.first?.chords.count == 9)
    }
    @Test func partialGroupsStayApart() {
        let v = build("""
        [mode.main.binding]
        cmd-alt-ctrl-shift-left = 'move left'
        cmd-alt-ctrl-shift-up = 'move up'
        """)
        #expect(v.aero.map(\.keys) == ["←", "↑"])
    }
    @Test func mainRowsSortByKindKeepingFileOrder() {
        let v = build("""
        [mode.main.binding]
        cmd-alt-ctrl-shift-r = 'mode resize'
        cmd-alt-ctrl-shift-a = 'workspace 1'
        cmd-alt-ctrl-shift-b = 'workspace 2'
        cmd-alt-ctrl-shift-c = 'move left'
        """)
        #expect(v.aero.map(\.keys) == ["C", "A", "B", "R"])
    }
    @Test func layerIsSetOnlyWhenTwoLayersHaveRows() {
        let a = AppKeys(layer: "one", entries: [KeyEntry(keys: "Caps\u{a0}Q", action: "A")])
        let b = AppKeys(layer: "two", entries: [KeyEntry(keys: "Caps\u{a0}P", action: "B")])
        let none = AppKeys(layer: "three", entries: [KeyEntry(keys: "⌘P", action: "C")])
        let two = build("", apps: [a, b])
        #expect(two.app.map(\.layer) == ["one", "two"])
        let one = build("", apps: [a, none])
        #expect(one.app.map(\.layer) == [nil])
    }
    @Test func freeKeysFollowKeyboardOrder() {
        let v = build("", mods: [.cmd])
        #expect(v.free.joined() == "1234567890QWERTYUIOPASDFGHJKL;'ZXCVBNM,./")
        let t = build("[mode.main.binding]\ncmd-alt-ctrl-shift-q = 'move left'", apps: [AppKeys(layer: "x", entries: [KeyEntry(keys: "Caps\u{a0}W", action: "W")])])
        #expect(t.free.prefix(12).joined() == "1234567890" + "E" + "R")
    }
    @Test func groupedRowShowsModsThatDifferInAnotherMode() {
        let v = ComboView.build(mods: [], mode: "nav", aero: .parse("""
        [mode.nav.binding]
        alt-left = 'move left'
        alt-down = 'move down'
        alt-up = 'move up'
        alt-right = 'move right'
        """), appName: "x", apps: [], hyperLabel: "Caps")
        #expect(v.aero.map(\.keys) == ["⌥ ← ↑ ↓ →"])
    }
    @Test func alsoListsWorkspaceKeysWithGroupedRange() {
        let toml = "[mode.main.binding]\ncmd-alt-ctrl-shift-1 = 'workspace 1'\n" + (1...9).map { "alt-ctrl-\($0) = 'workspace \($0)'" }.joined(separator: "\n")
        #expect(build(toml).also == ["Go to a workspace also: ⌃⌥ 1 – 9"])
    }
    @Test func alsoMarksGroupedSendRowAsFollow() {
        let toml = "[mode.main.binding]\ncmd-alt-ctrl-shift-w = 'move-node-to-workspace --wrap-around next'\n"
            + (1...9).map { "alt-ctrl-\($0) = 'move-node-to-workspace --focus-follows-window \($0)'" }.joined(separator: "\n")
        #expect(build(toml).also == ["Send to a workspace also: ⌃⌥ 1 – 9 (follow)"])
    }
}
