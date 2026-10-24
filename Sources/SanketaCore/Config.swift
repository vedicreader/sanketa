import Foundation
import Carbon.HIToolbox
import TOMLDecoder

/// How much of what's behind the panel shows through; `low` dims most.
public enum Translucency: String, Codable, CaseIterable { case low, medium, high }

/// The MLX model that runs on device for natural-language search.
public enum MLXModelChoice: String, Codable, CaseIterable, Sendable { case qwen4b = "qwen3.5-4b", qwen2b = "qwen3.5-2b" }

/// `[coach]`: where Sanketa reads shell history for coaching.
public struct CoachConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var fishHistory = "~/.local/share/fish/fish_history"
    public var bashHistory = "~/.bash_history"
    public var maxEntries = 5000

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, fishHistory = "fish_history", bashHistory = "bash_history", maxEntries = "max_entries"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        fishHistory = try c.decodeIfPresent(String.self, forKey: .fishHistory) ?? fishHistory
        bashHistory = try c.decodeIfPresent(String.self, forKey: .bashHistory) ?? bashHistory
        maxEntries = max(1, try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? maxEntries)
    }

    public var fishURL: URL { URL(fileURLWithPath: (fishHistory as NSString).expandingTildeInPath) }
    public var bashURL: URL { URL(fileURLWithPath: (bashHistory as NSString).expandingTildeInPath) }
}

/// `[llm]`: the model tiers for natural-language search and suggestions. OpenAI stays off until the user turns it on.
public struct LLMConfig: Codable, Equatable, Sendable {
    public var onDevice = true
    public var mlxModel = MLXModelChoice.qwen4b
    public var appleFM = true
    public var suggest = true
    public var openai = false
    public var openaiModel = ""
    public var baseURL = "https://api.openai.com/v1"
    /// The variable that holds the key. nil: `OPENAI_API_KEY`, and only for api.openai.com.
    public var apiKeyEnv: String?
    public var timeoutSeconds = 5.0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case onDevice = "on_device", mlxModel = "mlx_model", appleFM = "apple_fm", suggest, openai
        case openaiModel = "openai_model", baseURL = "base_url", apiKeyEnv = "api_key_env", timeoutSeconds = "timeout_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onDevice = try c.decodeIfPresent(Bool.self, forKey: .onDevice) ?? onDevice
        mlxModel = try c.decodeIfPresent(MLXModelChoice.self, forKey: .mlxModel) ?? mlxModel
        appleFM = try c.decodeIfPresent(Bool.self, forKey: .appleFM) ?? appleFM
        suggest = try c.decodeIfPresent(Bool.self, forKey: .suggest) ?? suggest
        openai = try c.decodeIfPresent(Bool.self, forKey: .openai) ?? openai
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? openaiModel
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        apiKeyEnv = try c.decodeIfPresent(String.self, forKey: .apiKeyEnv).flatMap { $0.isEmpty ? nil : $0 }
        if let v = try? c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) { timeoutSeconds = v }
        else { timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds).map(Double.init) ?? timeoutSeconds }
        if timeoutSeconds <= 0 { timeoutSeconds = LLMConfig().timeoutSeconds }
    }

    /// The variable to read the key from for this server: `api_key_env` when set, else `OPENAI_API_KEY` for
    /// api.openai.com only. nil: only a Keychain key saved for this host is sent.
    public func keyVariable(for baseURL: URL) -> String? {
        apiKeyEnv ?? (OpenAIModels.isOpenAI(baseURL) ? "OPENAI_API_KEY" : nil)
    }
}

public struct Config: Codable, Equatable {
    public var hotkey = "ctrl+opt+k"
    public var terminals = ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "fun.tw93.kaku"]
    public var pollInterval = 1.0
    public var tipRotateSeconds = 120.0
    public var translucency = Translucency.medium
    /// How Leela's Hyper (⌃⌥⇧⌘) shows in the panel; Caps Lock sends Hyper on the author's Mac.
    public var hyperLabel = "Caps"
    public var coach = CoachConfig()
    public var llm = LLMConfig()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case hotkey, terminals, pollInterval, tipRotateSeconds, translucency, coach, llm
        case hyperLabel = "hyper_label"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys, _ d: Double) throws -> Double {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v }
            return try c.decodeIfPresent(Int.self, forKey: k).map(Double.init) ?? d
        }
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        terminals = try c.decodeIfPresent([String].self, forKey: .terminals) ?? terminals
        pollInterval = try num(.pollInterval, pollInterval)
        tipRotateSeconds = try num(.tipRotateSeconds, tipRotateSeconds)
        hyperLabel = try c.decodeIfPresent(String.self, forKey: .hyperLabel) ?? hyperLabel
        coach = try c.decodeIfPresent(CoachConfig.self, forKey: .coach) ?? coach
        llm = try c.decodeIfPresent(LLMConfig.self, forKey: .llm) ?? llm
        translucency = (try? c.decodeIfPresent(String.self, forKey: .translucency)).flatMap { $0.flatMap(Translucency.init) } ?? .medium
    }

    /// `text` with `key = value` replaced, or inserted: before the first table, or with `table`, at the end of that
    /// table (which is added at the end of the text when missing). Other lines are kept.
    public static func setting(_ key: String, _ value: String, in text: String, table: String? = nil) -> String {
        var lines = text.components(separatedBy: "\n")
        let code = { (l: String) in (l.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? l)
            .trimmingCharacters(in: .whitespaces) }
        let isTable = { (l: String) in code(l).hasPrefix("[") }
        let new = "\(key) = \(value)"
        var range = 0..<(lines.firstIndex(where: isTable) ?? lines.count)
        if let table {
            guard let h = lines.firstIndex(where: { code($0) == "[\(table)]" }) else {
                return text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "\n[\(table)]\n\(new)\n"
            }
            range = (h + 1)..<(lines[(h + 1)...].firstIndex(where: isTable) ?? lines.count)
        }
        if let i = lines[range].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix(key) && t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) { lines[i] = new }
        else if table == nil { lines.insert(new, at: range.upperBound) }
        else {
            let last = lines[range].lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? range.lowerBound - 1
            lines.insert(new, at: last + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// Persists one key into the config file (top level, or inside `table`), creating the file if needed.
    public static func save(_ key: String, _ value: String, to url: URL, table: String? = nil) throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setting(key, value, in: old, table: table).write(to: url, atomically: true, encoding: .utf8)
    }

    /// A missing file gives defaults and no error; bad TOML gives defaults and a short message, such as `hotkey must be a string`.
    public static func load(_ url: URL) -> (Config, String?) {
        guard let data = try? Data(contentsOf: url) else { return (Config(), nil) }
        do { return (try TOMLDecoder().decode(Config.self, from: data), nil) }
        catch { return (Config(), PackLint.describe(error, root: "")) }
    }
}

public struct Hotkey: Equatable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    static let modifiers: [String: UInt32] = ["cmd": 256, "shift": 512, "opt": 2048, "alt": 2048, "ctrl": 4096]

    static let keys: [String: Int] = {
        var d: [String: Int] = [
            "space": kVK_Space, "/": kVK_ANSI_Slash, ".": kVK_ANSI_Period, ",": kVK_ANSI_Comma,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        let letters = [kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H,
                       kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P,
                       kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X,
                       kVK_ANSI_Y, kVK_ANSI_Z]
        for (c, k) in zip("abcdefghijklmnopqrstuvwxyz", letters) { d[String(c)] = k }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (c, k) in zip("0123456789", digits) { d[String(c)] = k }
        return d
    }()

    public init(keyCode: UInt32, carbonModifiers: UInt32) { self.keyCode = keyCode; self.carbonModifiers = carbonModifiers }

    /// Parses e.g. `ctrl+opt+k`; needs exactly one non-modifier key.
    public static func parse(_ s: String) -> Hotkey? {
        var mods: UInt32 = 0
        var key: Int?
        for tok in s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let m = modifiers[tok] { mods |= m }
            else if let k = keys[tok], key == nil { key = k }
            else { return nil }
        }
        return key.map { Hotkey(keyCode: UInt32($0), carbonModifiers: mods) }
    }
}
