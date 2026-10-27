import Testing
import Foundation
@testable import SanketaCore

@Suite struct AeroSpaceConfigTests {
    @Test func readsModesAndLines() {
        let c = AeroSpaceConfig.parse(aeroSample)
        #expect(Set(c.modes.keys) == ["main", "resize"])
        let main = c.modes["main"]!
        #expect(main.count == 8)
        #expect(main.first { $0.chord.key == "3" && $0.chord.mods.count == 3 }?.action == "Send the tile to 3")
        #expect(main.first { $0.chord.mods == [.opt, .ctrl] }?.action == "Send the tile to 3 and follow")
        #expect(main.first { $0.chord.key == "left" }?.kind == .moveTile)
        #expect(main.first { $0.chord.key == "`" }?.action == "Run a script")
        #expect(main.first { $0.chord.key == "r" }?.line == 10)
        #expect(main.first { $0.chord.key == "e" }?.commands == ["balance-sizes", "mode main"])
        #expect(main.first { $0.chord.key == "e" }?.kind == .resize)   // the first command names the binding
        #expect(c.modes["resize"]!.map(\.chord.key) == ["-", "esc"])
    }
    @Test func linesSurviveMultiLineStrings() {
        let main = AeroSpaceConfig.parse(aeroSample).modes["main"]!
        #expect(main.first { $0.chord.key == "e" }?.line == 13)
        #expect(AeroSpaceConfig.parse(aeroSample).modes["resize"]!.map(\.line) == [15, 16])
    }
    @Test func namesCommandsInPlainWords() {
        #expect(AeroSpaceConfig.describe(["workspace 3"]).action == "Go to workspace 3")
        #expect(AeroSpaceConfig.describe(["workspace --wrap-around prev"]).action == "Previous workspace")
        #expect(AeroSpaceConfig.describe(["move-node-to-workspace --wrap-around prev"]).action == "Send the tile to the previous workspace")
        #expect(AeroSpaceConfig.describe(["focus left"]) == ("Focus left", .focus, "left"))
        #expect(AeroSpaceConfig.describe(["mode main"]).action == "Back to normal")
        #expect(AeroSpaceConfig.describe(["mode resize"]).action == "resize mode")
        #expect(AeroSpaceConfig.describe(["resize smart +50"]).action == "Make it bigger")
        #expect(AeroSpaceConfig.describe(["resize smart -50"]).action == "Make it smaller")
        #expect(AeroSpaceConfig.describe(["focus-monitor --wrap-around next"]).action == "Focus the next monitor")
        #expect(AeroSpaceConfig.describe(["join-with left"]).kind == .other)
        #expect(AeroSpaceConfig.describe(["workspace 3"]).target == "3")
    }
    @Test func findsTheFile() {
        let home = URL(fileURLWithPath: "/h")
        #expect(AeroSpaceConfig.url(env: [:], home: home, fileExists: { $0 == "/h/.aerospace.toml" })?.path == "/h/.aerospace.toml")
        #expect(AeroSpaceConfig.url(env: ["XDG_CONFIG_HOME": "/x"], home: home, fileExists: { $0 == "/x/aerospace/aerospace.toml" })?.path == "/x/aerospace/aerospace.toml")
        #expect(AeroSpaceConfig.url(env: [:], home: home, fileExists: { _ in false }) == nil)
    }

    @Test func namesEveryRowOfThePlainTable() {
        let rows: [(String, String, AeroKind)] = [
            ("focus dfs-next", "Focus next", .focus), ("focus dfs-prev", "Focus previous", .focus),
            ("workspace-back-and-forth", "Last workspace", .workspace),
            ("workspace --wrap-around next", "Next workspace", .workspace),
            ("move-node-to-workspace --wrap-around next", "Send the tile to the next workspace", .sendToWorkspace),
            ("layout floating tiling", "Float or tile", .layout), ("layout accordion tiles", "Accordion or tiles", .layout),
            ("layout horizontal vertical", "Side by side or stacked", .layout), ("fullscreen", "Full screen", .layout),
            ("exec-and-forget echo hi", "Run a script", .script), ("balance-sizes", "Balance sizes", .resize),
            ("focus-monitor --wrap-around prev", "Focus the previous monitor", .monitor),
            ("focus-monitor --wrap-around next", "Focus the next monitor", .monitor),
            ("move-node-to-workspace 4", "Send the tile to 4", .sendToWorkspace),
            ("move up", "Move the tile up", .moveTile),
            ("join-with left", "join-with left", .other)]
        for (cmd, action, kind) in rows {
            let d = AeroSpaceConfig.describe([cmd])
            #expect(d.action == action, "\(cmd)")
            #expect(d.kind == kind, "\(cmd)")
        }
    }
    @Test func readsQuotesEscapesAndComments() {
        let c = AeroSpaceConfig.parse("""
        [mode.main.binding]
        alt-a = "exec-and-forget say \\"hi\\""
        alt-b = 'exec-and-forget echo # not a comment' # a comment
        "cmd-alt-ctrl-shift-x" = 'fullscreen'
        alt-z = 'workspace 9'
        """).modes["main"]!
        #expect(c.map(\.line) == [2, 3, 4, 5])
        #expect(c[0].commands == ["exec-and-forget say \"hi\""])
        #expect(c[1].commands == ["exec-and-forget echo # not a comment"])
        #expect(c[2].chord.key == "x" && c[2].chord.isHyper && c[2].action == "Full screen")
        #expect(c[3].action == "Go to workspace 9")
    }
    @Test func readsTripleDoubleQuotesAndMultiLineArrays() {
        let c = AeroSpaceConfig.parse("""
        [mode.main.binding] # the main mode
        alt-a = \"\"\"
        exec-and-forget echo a
        echo b\"\"\"
        alt-b = [ # first
          'balance-sizes', # one
          # between
          'mode main'
        ]
        alt-c = 'fullscreen'
        """).modes["main"]!
        #expect(c.map(\.line) == [2, 5, 10])
        #expect(c[0].commands == ["exec-and-forget echo a\necho b"])
        #expect(c[0].kind == .script)
        #expect(c[1].commands == ["balance-sizes", "mode main"])
        #expect(c[2].action == "Full screen")
    }
    @Test func readsCRLFFiles() {
        let a = AeroSpaceConfig.parse(aeroSample), b = AeroSpaceConfig.parse(aeroSample.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(a.modes == b.modes)
    }
}

