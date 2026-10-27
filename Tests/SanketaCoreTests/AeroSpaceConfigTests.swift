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
}
