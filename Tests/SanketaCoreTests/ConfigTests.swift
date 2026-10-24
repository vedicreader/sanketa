import Testing
import Foundation
import Carbon.HIToolbox
@testable import SanketaCore

func writeConfig(_ text: String) throws -> URL {
    let u = try tempDir().appendingPathComponent("config.toml")
    try Data(text.utf8).write(to: u)
    return u
}

struct ConfigTests {
    @Test func defaultsWhenMissing() throws {
        let (c, err) = Config.load(try tempDir().appendingPathComponent("config.toml"))
        #expect(err == nil && c == Config())
        #expect(c.hotkey == "ctrl+opt+k" && c.pollInterval == 1.0 && c.tipRotateSeconds == 120)
        #expect(c.terminals == ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "fun.tw93.kaku"])
    }

    @Test func partialConfigKeepsDefaults() throws {
        let (c, err) = Config.load(try writeConfig("hotkey = \"cmd+shift+space\"\n\n[llm]\nmodel = \"x\"\n"))
        #expect(err == nil)
        #expect(c.hotkey == "cmd+shift+space")
        #expect(c.terminals == Config().terminals && c.pollInterval == 1.0)
    }

    @Test func hyperLabelDefaultsToCapsAndIsConfigurable() throws {
        #expect(Config().hyperLabel == "Caps")
        let (c, err) = Config.load(try writeConfig("hyper_label = \"Hyper\"\n"))
        #expect(err == nil && c.hyperLabel == "Hyper")
    }

    @Test func badTomlReturnsError() throws {
        let (c, err) = Config.load(try writeConfig("hotkey = = oops ["))
        #expect(err?.hasPrefix("line 1: ") == true && c == Config())
        // the footer shows the message: short, with no Swift type names
        let h = Config.load(try writeConfig("hotkey = 3\n")).1, t = Config.load(try writeConfig("terminals = \"a.b\"\n")).1
        #expect(h == "line 1: hotkey must be a string", "\(h ?? "nil")")
        #expect(t == "terminals must be a list", "\(t ?? "nil")")
    }

    @Test func integerPollIntervalAccepted() throws {
        let (c, err) = Config.load(try writeConfig("pollInterval = 2\ntipRotateSeconds = 30\nterminals = [\"a.b\"]\n"))
        #expect(err == nil && c.pollInterval == 2.0 && c.tipRotateSeconds == 30.0 && c.terminals == ["a.b"])
        let (d, _) = Config.load(try writeConfig("pollInterval = 0.5\n"))
        #expect(d.pollInterval == 0.5)
    }

    @Test func parseCtrlOptK() {
        let h = Hotkey.parse("ctrl+opt+k")
        #expect(h?.keyCode == UInt32(kVK_ANSI_K) && h?.carbonModifiers == 6144)
        #expect(Hotkey.parse("Cmd + Shift + F5") == Hotkey(keyCode: UInt32(kVK_F5), carbonModifiers: 768))
        #expect(Hotkey.parse("alt+space")?.carbonModifiers == 2048)
        #expect(Hotkey.parse("cmd+/")?.keyCode == UInt32(kVK_ANSI_Slash))
        #expect(Hotkey.parse("ctrl+9")?.keyCode == UInt32(kVK_ANSI_9))
    }

    @Test func parseRejectsTwoKeys() { #expect(Hotkey.parse("ctrl+a+b") == nil) }
    @Test func parseRejectsNoKey() { #expect(Hotkey.parse("ctrl+opt") == nil); #expect(Hotkey.parse("") == nil) }
    @Test func parseRejectsUnknownKey() { #expect(Hotkey.parse("ctrl+banana") == nil) }
}

struct TranslucencyConfigTests {
    @Test func translucencyParsesAndFallsBack() throws {
        #expect(Config().translucency == .medium)
        #expect(Config.load(try writeConfig("translucency = \"low\"\n")).0.translucency == .low)
        #expect(Config.load(try writeConfig("translucency = \"high\"\n")).0.translucency == .high)
        let (c, err) = Config.load(try writeConfig("translucency = \"glassy\"\nhotkey = \"cmd+k\"\n"))
        #expect(err == nil && c.translucency == .medium && c.hotkey == "cmd+k")
    }

    @Test func savingKeepsTheRestOfTheFile() throws {
        let text = "# my settings\nhotkey = \"cmd+k\"   \ntranslucency = \"low\"\n\n[llm]\ntranslucency = \"x\"\n"
        let u = try writeConfig(text)
        try Config.save("translucency", "\"high\"", to: u)
        let after = try String(contentsOf: u, encoding: .utf8)
        #expect(after == text.replacingOccurrences(of: "translucency = \"low\"", with: "translucency = \"high\""))
        #expect(Config.load(u).0.translucency == .high && Config.load(u).0.hotkey == "cmd+k")

        let v = try writeConfig("hotkey = \"cmd+k\"\n[llm]\nmodel = \"m\"\n")
        try Config.save("translucency", "\"low\"", to: v)
        #expect(try String(contentsOf: v, encoding: .utf8) == "hotkey = \"cmd+k\"\ntranslucency = \"low\"\n[llm]\nmodel = \"m\"\n")
        let missing = try tempDir().appendingPathComponent("sub/config.toml")
        try Config.save("translucency", "\"high\"", to: missing)
        #expect(Config.load(missing).0.translucency == .high)
    }
}
