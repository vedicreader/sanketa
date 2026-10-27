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
        let (c, err, _) = Config.load(try tempDir().appendingPathComponent("config.toml"))
        #expect(err == nil && c == Config())
        #expect(c.hotkey == "ctrl+opt+k" && c.pollInterval == 1.0 && c.tipRotateSeconds == 120)
        #expect(c.terminals == ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "fun.tw93.kaku"])
    }

    @Test func partialConfigKeepsDefaults() throws {
        let (c, err, _) = Config.load(try writeConfig("hotkey = \"cmd+shift+space\"\n\n[llm]\nmodel = \"x\"\n"))
        #expect(err == nil)
        #expect(c.hotkey == "cmd+shift+space")
        #expect(c.terminals == Config().terminals && c.pollInterval == 1.0)
    }

    @Test func holdDelayDefaultsShortAndStaysInRange() throws {
        #expect(Config().holdDelay == 0.25)
        #expect(Config.load(try writeConfig("hold_delay = 0.5\n")).0.holdDelay == 0.5)
        #expect(Config.load(try writeConfig("hold_delay = 1\n")).0.holdDelay == 1)
        #expect(Config.load(try writeConfig("hold_delay = 0\n")).0.holdDelay == 0.1)
        #expect(Config.load(try writeConfig("hold_delay = 9\n")).0.holdDelay == 2)
    }

    @Test func hyperLabelDefaultsToCapsAndIsConfigurable() throws {
        #expect(Config().hyperLabel == "Caps")
        let (c, err, _) = Config.load(try writeConfig("hyper_label = \"Hyper\"\n"))
        #expect(err == nil && c.hyperLabel == "Hyper")
    }

    @Test func badTomlReturnsError() throws {
        let (c, err, _) = Config.load(try writeConfig("hotkey = = oops ["))
        #expect(err?.hasPrefix("line 1: ") == true && c == Config())
        // the footer shows the message: short, with no Swift type names
        let h = Config.load(try writeConfig("hotkey = 3\n")).1, t = Config.load(try writeConfig("terminals = \"a.b\"\n")).1
        #expect(h == "line 1: hotkey must be a string", "\(h ?? "nil")")
        #expect(t == "terminals must be a list", "\(t ?? "nil")")
    }

    @Test func integerPollIntervalAccepted() throws {
        let (c, err, _) = Config.load(try writeConfig("pollInterval = 2\ntipRotateSeconds = 30\nterminals = [\"a.b\"]\n"))
        #expect(err == nil && c.pollInterval == 2.0 && c.tipRotateSeconds == 30.0 && c.terminals == ["a.b"])
        let (d, _, _) = Config.load(try writeConfig("pollInterval = 0.5\n"))
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
        let (c, err, _) = Config.load(try writeConfig("translucency = \"glassy\"\nhotkey = \"cmd+k\"\n"))
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

struct CoachLLMConfigTests {
    @Test func llmDefaultsKeepOpenAIOff() throws {
        let (c, err, _) = Config.load(try writeConfig(""))
        #expect(err == nil)
        #expect(c.llm.openai == false && c.llm.onDevice == false && c.llm.appleFM == true)
        #expect(c.llm.openaiModel == "" && c.llm.baseURL == "https://api.openai.com/v1" && c.coach.enabled == true)
    }

    @Test func llmTableParses() throws {
        let (c, err, _) = Config.load(try writeConfig("[llm]\nopenai = true\nopenai_model = \"gpt-x\"\nbase_url = \"http://localhost:11434/v1\"\nmlx_model = \"qwen3.5-2b\""))
        #expect(err == nil)
        #expect(c.llm.openai && c.llm.openaiModel == "gpt-x" && c.llm.baseURL == "http://localhost:11434/v1")
        #expect(c.llm.mlxModel == .qwen2b && c.llm.suggest == true)
    }

    @Test func gemmaOnlyOnSixteenGigabytesOrMore() throws {
        #expect(MLXModelChoice.recommended(memory: 16 << 30) == .gemma4e4b)
        #expect(MLXModelChoice.recommended(memory: 8 << 30) == .qwen4b)
        #expect(MLXModelChoice.offered(memory: 36 << 30) == [.gemma4e4b, .qwen4b, .qwen2b])
        #expect(MLXModelChoice.offered(memory: 8 << 30) == [.qwen4b, .qwen2b])
        let gemma = Config.load(try writeConfig("[llm]\nmlx_model = \"gemma-4-e4b\"")).0.llm
        #expect(gemma.mlxModel == .gemma4e4b)
        #expect(Config.load(try writeConfig("")).0.llm.mlxModel == MLXModelChoice.recommended())
        // a Mac with too little memory: one warning, and the model that fits
        let (small, err, warn) = Config.load(try writeConfig("[llm]\non_device = true\nmlx_model = \"gemma-4-e4b\""), memory: 8 << 30)
        #expect(small.llm.mlxModel == .qwen4b && err == nil, "the file loaded: a note, not an error")
        #expect(warn == "Gemma 4 E4B needs 16 GB of memory. This Mac has 8 GB. No model that fits is downloaded, so the on-device model is off.")
        #expect(Config.load(try writeConfig("[llm]\nmlx_model = \"qwen3.5-2b\""), memory: 8 << 30).note == nil)
    }

    /// The rule: peak memory from the bench plus 3 GB, rounded up to a multiple of 8 GB.
    @Test func modelsNeedTheirMemory() {
        #expect(MLXModelChoice.allCases.map { $0.minMemory >> 30 } == [16, 8, 8, 8])
        #expect(MLXModelChoice.memoryFloor == 8 << 30)
        let offered: [UInt64: [MLXModelChoice]] = [4: [], 8: [.qwen4b, .qwen2b], 16: [.gemma4e4b, .qwen4b, .qwen2b],
                                                   32: [.gemma4e4b, .qwen4b, .qwen2b]]
        for (gb, want) in offered {
            #expect(MLXModelChoice.offered(memory: gb << 30) == want, "\(gb) GB")
            #expect(MLXModelChoice.anyFits(memory: gb << 30) == (gb >= 8), "\(gb) GB")
        }
    }

    /// No model is used until the user chooses one; a model that is already installed and chosen stays on.
    @Test func onDeviceIsOffUntilAModelIsChosen() throws {
        let none = { (_: MLXModelChoice) in false }, gemma = { (c: MLXModelChoice) in c == .gemma4e4b }
        #expect(Config().llm.onDevice == false)
        #expect(Config.load(try tempDir().appendingPathComponent("missing.toml"), memory: 16 << 30, installed: none).0.llm.onDevice == false)
        #expect(Config.load(try writeConfig(""), memory: 16 << 30, installed: none).0.llm.onDevice == false)
        // a user who downloaded Gemma before this change: no on_device line, the default model is installed
        #expect(Config.load(try tempDir().appendingPathComponent("missing.toml"), memory: 16 << 30, installed: gemma).0.llm.onDevice)
        #expect(Config.load(try writeConfig("[llm]\nmlx_model = \"gemma-4-e4b\""), memory: 16 << 30, installed: gemma).0.llm.onDevice)
        // another model is chosen than the one installed: the installed one that fits
        let other = Config.load(try writeConfig("[llm]\nmlx_model = \"qwen3.5-2b\""), memory: 16 << 30, installed: gemma).0.llm
        #expect(other.onDevice && other.mlxModel == .gemma4e4b)
        // the user's own value wins
        #expect(!Config.load(try writeConfig("[llm]\non_device = false"), memory: 16 << 30, installed: gemma).0.llm.onDevice)
        #expect(Config.load(try writeConfig("[llm]\non_device = true"), memory: 16 << 30, installed: none).0.llm.onDevice)
        // a 4 GB Mac: off, with one note when the user had turned it on
        let (small, err, note) = Config.load(try writeConfig("[llm]\non_device = true"), memory: 4 << 30, installed: gemma)
        #expect(!small.llm.onDevice && err == nil && note == MLXModelChoice.notEnoughMemory)
        let quiet = Config.load(try writeConfig(""), memory: 4 << 30, installed: none)
        #expect(!quiet.config.llm.onDevice && quiet.note == nil)
    }

    /// With no on_device line, a downloaded model that fits is used when the chosen one is not downloaded.
    @Test func migrationUsesAnotherInstalledModelThatFits() throws {
        let qwen = { (c: MLXModelChoice) in c == .qwen2b }
        let l = Config.load(try writeConfig("[llm]\nmlx_model = \"gemma-4-e4b\""), memory: 16 << 30, installed: qwen).0.llm
        #expect(l.onDevice && l.mlxModel == .qwen2b)
        // Gemma downloaded on a Mac that is too small for it: the Qwen that is also downloaded
        let both = { (c: MLXModelChoice) in c == .qwen2b || c == .gemma4e4b }
        let s = Config.load(try writeConfig("[llm]\nmlx_model = \"gemma-4-e4b\""), memory: 8 << 30, installed: both).0.llm
        #expect(s.onDevice && s.mlxModel == .qwen2b)
    }

    /// A model that is on but too big changes to a downloaded model that fits; with none, the model goes off.
    @Test func tooBigModelNeverStaysOnWithNoModel() throws {
        let none = { (_: MLXModelChoice) in false }, qwen4 = { (c: MLXModelChoice) in c == .qwen4b }
        let (off, _, note) = Config.load(try writeConfig("[llm]\non_device = true\nmlx_model = \"gemma-4-e4b\""), memory: 8 << 30, installed: none)
        #expect(!off.llm.onDevice)
        #expect(note == "Gemma 4 E4B needs 16 GB of memory. This Mac has 8 GB. No model that fits is downloaded, so the on-device model is off.")
        let (on, _, n2) = Config.load(try writeConfig("[llm]\non_device = true\nmlx_model = \"gemma-4-e4b\""), memory: 8 << 30, installed: qwen4)
        #expect(on.llm.onDevice && on.llm.mlxModel == .qwen4b)
        #expect(n2 == "Gemma 4 E4B needs 16 GB of memory. This Mac has 8 GB. Sanketa uses Qwen3.5-4B.")
    }

    @Test func keyVariableOnlyForOpenAIUnlessSet() throws {
        let openAI = try #require(URL(string: "https://api.openai.com/v1")), local = try #require(URL(string: "http://localhost:1234/v1"))
        let plain = Config.load(try writeConfig("[llm]\nopenai = true")).0.llm
        #expect(plain.keyVariable(for: openAI) == "OPENAI_API_KEY" && plain.keyVariable(for: local) == nil)
        let set = Config.load(try writeConfig("[llm]\napi_key_env = \"LOCAL_KEY\"")).0.llm
        #expect(set.keyVariable(for: openAI) == "LOCAL_KEY" && set.keyVariable(for: local) == "LOCAL_KEY")
        #expect(Config.load(try writeConfig("[llm]\napi_key_env = \"\"")).0.llm.keyVariable(for: local) == nil)
    }

    @Test func integerTimeoutAccepted() throws {
        #expect(Config.load(try writeConfig("[llm]\ntimeout_seconds = 3")).0.llm.timeoutSeconds == 3.0)
    }

    @Test func coachPathsExpandTilde() {
        #expect(CoachConfig().fishURL.path == NSHomeDirectory() + "/.local/share/fish/fish_history")
        #expect(CoachConfig().bashURL.path == NSHomeDirectory() + "/.bash_history")
    }

    @Test func badLLMTypeReturnsError() throws {
        for t in ["[llm]\nopenai = \"yes\"", "[llm]\nmlx_model = \"huge\""] {
            let (c, err, _) = Config.load(try writeConfig(t))
            #expect(err != nil && c == Config(), "\(t)")
        }
    }

    @Test func tableSettingReplacesInsideTable() throws {
        let text = "hotkey = \"x\"\n[llm]\nopenai = true\nopenai_model = \"a\"\n[coach]\nenabled = true\n"
        let a = Config.setting("openai_model", "\"b\"", in: text, table: "llm")
        #expect(a == "hotkey = \"x\"\n[llm]\nopenai = true\nopenai_model = \"b\"\n[coach]\nenabled = true\n")
        #expect(Config.load(try writeConfig(a)).0.llm.openaiModel == "b")
        let b = Config.setting("base_url", "\"u\"", in: text, table: "llm")
        #expect(b == "hotkey = \"x\"\n[llm]\nopenai = true\nopenai_model = \"a\"\nbase_url = \"u\"\n[coach]\nenabled = true\n")
        #expect(Config.load(try writeConfig(b)).0.llm.baseURL == "u")
        let c = Config.setting("openai_model", "\"b\"", in: "hotkey = \"x\"\n", table: "llm")
        #expect(c.hasSuffix("\n[llm]\nopenai_model = \"b\"\n"))
        #expect(Config.load(try writeConfig(c)).0.llm.openaiModel == "b")
    }

    @Test func saveWithTableWritesFile() throws {
        let u = try tempDir().appendingPathComponent("config.toml")
        try Config.save("openai_model", "\"m\"", to: u, table: "llm")
        #expect(Config.load(u).0.llm.openaiModel == "m")
    }

    @Test func tableHeaderWithCommentIsFound() throws {
        let text = "[llm]  # note\nopenai = true\n[coach]\n"
        let a = Config.setting("openai_model", "\"b\"", in: text, table: "llm")
        #expect(a == "[llm]  # note\nopenai = true\nopenai_model = \"b\"\n[coach]\n")
        #expect(Config.load(try writeConfig(a)).0.llm.openaiModel == "b")
    }

    @Test func nonPositiveLimitsAreClamped() throws {
        let (c, err, _) = Config.load(try writeConfig("[llm]\ntimeout_seconds = 0\n[coach]\nmax_entries = -4"))
        #expect(err == nil && c.llm.timeoutSeconds == 5 && c.coach.maxEntries == 1)
        #expect(Config.load(try writeConfig("[llm]\ntimeout_seconds = -1.5")).0.llm.timeoutSeconds == 5)
    }
}

struct ConfigReadTests {
    @Test func changesNameTheKeysInFileSpelling() {
        let old = Config()
        #expect(old.changes(from: old).isEmpty)
        var c = old
        c.holdDelay = 0.5; c.hotkey = "cmd+k"; c.pollInterval = 2; c.tipRotateSeconds = 5; c.hyperLabel = "X"
        c.translucency = .low; c.hold = .off; c.terminals = ["a"]
        #expect(c.changes(from: old) == ["hotkey", "terminals", "pollInterval", "tipRotateSeconds", "translucency", "hyper_label", "hold", "hold_delay"])
    }

    @Test func aChangeInATableNamesTheTable() {
        let old = Config()
        var c = old
        c.coach.maxEntries = 1; c.llm.openai = true; c.vault.mcp = false; c.abhyasa.enabled = false
        #expect(c.changes(from: old) == ["[coach]", "[llm]", "[vault]", "[abhyasa]"])
    }

    @Test func textForChangesNothingAndError() {
        #expect(ConfigRead.text(changes: ["hold_delay", "hotkey"], error: nil) == "Sanketa read config.toml: hold_delay, hotkey.")
        #expect(ConfigRead.text(changes: [], error: nil) == "Sanketa read config.toml. Nothing changed.")
        #expect(ConfigRead.text(changes: ["a", "b", "c", "d"], error: nil) == "Sanketa read config.toml: a, b, c, d.")
        #expect(ConfigRead.text(changes: ["a", "b", "c", "d", "e", "f"], error: nil) == "Sanketa read config.toml: a, b, c, d, and 2 more.")
        #expect(ConfigRead.text(changes: ["a"], error: "hotkey must be a string")
                == "Sanketa cannot read config.toml: hotkey must be a string. It keeps the last good settings.")
        #expect(ConfigRead.text(changes: [], error: "bad.") == "Sanketa cannot read config.toml: bad. It keeps the last good settings.")
    }

    @Test func anErrorKeepsTheCurrentConfig() {
        var cur = Config(), new = Config()
        cur.hotkey = "cmd+k"
        #expect(ConfigRead.next(current: cur, loaded: Config(), error: "bad").hotkey == "cmd+k")
        new.hotkey = "cmd+j"
        #expect(ConfigRead.next(current: cur, loaded: new, error: nil).hotkey == "cmd+j")
    }

    @Test func ownWritesStayQuietInsideTheWindow() {
        let t = Date(timeIntervalSince1970: 1000)
        #expect(ConfigRead.announce(now: t, ownWriteUntil: nil))
        #expect(!ConfigRead.announce(now: t, ownWriteUntil: t.addingTimeInterval(1)))
        #expect(ConfigRead.announce(now: t, ownWriteUntil: t))
        #expect(ConfigRead.announce(now: t, ownWriteUntil: t.addingTimeInterval(1), forced: true))
    }
}
