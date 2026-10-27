import Testing
@testable import SanketaCore

/// The thin AeroSpace bar under the menu bar: a short word for each binding, the rows of the combo view, and the wrap.
@Suite struct AeroBarTests {
    let hyper = Set(Modifier.allCases)

    @Test func shortLabelsHaveAtMostTwoWords() {
        let cases: [([String], String)] = [
            (["move left"], "Move"), (["focus up"], "Focus"), (["focus dfs-next"], "Next"), (["focus dfs-prev"], "Previous"),
            (["workspace 3"], "Workspace"), (["workspace --wrap-around next"], "Next"), (["workspace --wrap-around prev"], "Previous"),
            (["workspace-back-and-forth"], "Last"), (["move-node-to-workspace 3"], "Send"),
            (["move-node-to-workspace --wrap-around next"], "Send next"), (["move-node-to-workspace --wrap-around prev"], "Send previous"),
            (["fullscreen"], "Full"), (["layout floating tiling"], "Float"), (["layout accordion tiles"], "Accordion"),
            (["layout horizontal vertical"], "Side by side"), (["focus-monitor next"], "Monitor"), (["mode resize"], "resize"),
            (["mode main"], "Back"), (["exec-and-forget open -a Notes"], "Script"), (["resize smart -50"], "Smaller"),
            (["resize smart +50"], "Bigger"), (["resize width -50"], "Narrower"), (["resize width +50"], "Wider"),
            (["resize height -50"], "Shorter"), (["resize height +50"], "Taller"), (["balance-sizes", "mode main"], "Balance"),
            (["join-with left"], "join-with"),
        ]
        for (c, want) in cases { #expect(AeroSpaceConfig.short(c) == want, "\(c)") }
        #expect(cases.allSatisfy { AeroSpaceConfig.short($0.0).split(separator: " ").count <= 3 })
    }

    @Test func theLongActionStaysForThePanel() {
        let b = AeroSpaceConfig.parse("[mode.main.binding]\nalt-ctrl-left = 'move left'").modes["main"]![0]
        #expect(b.action == "Move the tile left")
        #expect(b.short == "Move")
    }

    static let grouped: String = {
        let p = "cmd-alt-ctrl-shift-"
        var l = ["[mode.main.binding]"]
        l += ["left", "down", "up", "right"].map { "\(p)\($0) = 'move \($0)'" }
        l += zip(["h", "j", "k", "l"], ["left", "down", "up", "right"]).map { "\(p)\($0) = 'focus \($1)'" }
        l += (1...9).map { "\(p)\($0) = 'workspace \($0)'" }
        l += ["\(p)space = 'layout floating tiling'", "\(p)tab = 'workspace-back-and-forth'", "\(p)r = 'mode resize'",
              "[mode.resize.binding]", "left = 'resize width -50'", "right = 'resize width +50'", "esc = 'mode main'"]
        return l.joined(separator: "\n")
    }()

    @Test func theBarGroupsKeysAsTheComboViewDoes() throws {
        let v = ComboView.build(mods: hyper, mode: "main", aero: .parse(Self.grouped), appName: "x", apps: [], hyperLabel: "Caps")
        let bar = try #require(AeroBar(view: v))
        #expect(bar.lead == nil)
        #expect(bar.items.map(\.keys) == ["←↑↓→", "HJKL", "1–9", "tab", "space", "R"])
        #expect(bar.items.map(\.word) == ["Move", "Focus", "Workspace", "Last", "Float", "resize"])
        #expect(AeroBar.tail == "· AeroSpace")
    }

    @Test func aModeLeadsWithItsName() throws {
        let v = ComboView.build(mods: [], mode: "resize", aero: .parse(Self.grouped), appName: "x", apps: [], hyperLabel: "Caps")
        let bar = try #require(AeroBar(view: v))
        #expect(bar.lead == "resize mode ·")
        #expect(bar.items.map(\.keys) == ["←", "→", "esc"])
        #expect(bar.items.map(\.word) == ["Narrower", "Wider", "Back"])
    }

    @Test func noAeroSpaceKeysMeansNoBar() {
        let v = ComboView.build(mods: [.ctrl, .opt], mode: "main", aero: .parse(Self.grouped), appName: "x", apps: [], hyperLabel: "Caps")
        #expect(AeroBar(view: v) == nil)
        #expect(AeroBar(view: ComboView.build(mods: hyper, mode: "main", aero: nil, appName: "x", apps: [], hyperLabel: "Caps")) == nil)
    }

    @Test func theBarWrapsOnlyWhenItIsTooWide() {
        #expect(AeroBar.wrap([100, 100, 100], gap: 18, max: 400) == [[0, 1, 2]])   // 336
        #expect(AeroBar.wrap([100, 100, 100], gap: 18, max: 300) == [[0, 1], [2]])
        #expect(AeroBar.wrap([500, 50], gap: 18, max: 300) == [[0], [1]])   // a wide item takes a line of its own
        #expect(AeroBar.wrap([], gap: 18, max: 300) == [])
        #expect(AeroBar.maxShare == 0.8)
    }
}
