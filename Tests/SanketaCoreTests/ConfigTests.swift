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
        #expect(c.terminals == ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2"])
    }

    @Test func partialConfigKeepsDefaults() throws {
        let (c, err) = Config.load(try writeConfig("hotkey = \"cmd+shift+space\"\n\n[llm]\nmodel = \"x\"\n"))
        #expect(err == nil)
        #expect(c.hotkey == "cmd+shift+space")
        #expect(c.terminals == Config().terminals && c.pollInterval == 1.0)
    }

    @Test func badTomlReturnsError() throws {
        let (c, err) = Config.load(try writeConfig("hotkey = = oops ["))
        #expect(err != nil && c == Config())
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
