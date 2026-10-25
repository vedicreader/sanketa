import Foundation
import Carbon.HIToolbox
import TOMLDecoder

/// How much of what's behind the panel shows through; `low` dims most.
public enum Translucency: String, Codable, CaseIterable { case low, medium, high }

/// The MLX model that runs on device for natural-language search.
public enum MLXModelChoice: String, Codable, CaseIterable, Sendable {
    case gemma4e4b = "gemma-4-e4b", qwen4b = "qwen3.5-4b", qwen2b = "qwen3.5-2b", qwen4b6 = "qwen3.5-4b-6bit"

    /// Offered only when Gemma 4 E4B does not load on this Mac (or when it is already chosen or downloaded).
    public var isFallback: Bool { self == .qwen4b6 }

    /// The name in menus and in the search note.
    public var displayName: String {
        switch self {
        case .gemma4e4b: "Gemma 4 E4B"
        case .qwen4b: "Qwen3.5-4B"
        case .qwen2b: "Qwen3.5-2B"
        case .qwen4b6: "Qwen3.5-4B 6-bit"
        }
    }

    /// The most memory the model used while it ran in the bench (.superpowers/phase2/model-bench.md): the larger of
    /// the peak Metal memory and the peak RSS, in GB.
    public var peakMemoryGB: Double {
        switch self {
        case .gemma4e4b: 5.71
        case .qwen4b6: 4.65
        case .qwen4b: 3.66
        case .qwen2b: 2.28
        }
    }

    /// The memory a Mac needs before Sanketa offers this model. The rule: the model's peak memory plus 3 GB for macOS
    /// and the apps that you use, rounded up to a multiple of 8 GB. That gives 16 GB for Gemma 4 E4B and 8 GB for each
    /// Qwen model.
    public var minMemory: UInt64 {
        let gb = UInt64((peakMemoryGB + Self.headroomGB).rounded(.up))
        return (gb + 7) / 8 * 8 << 30
    }

    /// The memory that macOS and the user's apps keep, on top of the model.
    public static let headroomGB = 3.0

    /// The smallest `minMemory`: below it, no on-device model can run.
    public static var memoryFloor: UInt64 { allCases.map(\.minMemory).min() ?? 0 }

    /// True when the Mac has the memory for at least one model.
    public static func anyFits(memory: UInt64) -> Bool { memory >= memoryFloor }

    /// The menu line and the config note on a Mac below `memoryFloor`.
    public static let notEnoughMemory = "This Mac does not have enough memory for an on-device model. Search uses plain search."

    /// Gemma 4 E4B on a Mac with 16 GB or more, else Qwen3.5-4B.
    public static func recommended(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MLXModelChoice {
        memory >= gemma4e4b.minMemory ? .gemma4e4b : .qwen4b
    }

    /// "Gemma 4 E4B needs 16 GB of memory. This Mac has 8 GB."
    public static func memoryWarning(_ c: MLXModelChoice, memory: UInt64) -> String {
        "\(c.displayName) needs \(c.minMemory >> 30) GB of memory. This Mac has \(memory >> 30) GB."
    }

    /// The models to offer on a Mac with `memory` bytes.
    public static func offered(memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [MLXModelChoice] {
        allCases.filter { memory >= $0.minMemory && !$0.isFallback }
    }
}

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
/// The on-device model is off too, until the user chooses one in the On-Device Model menu or with `--install-model`.
public struct LLMConfig: Codable, Equatable, Sendable {
    public var onDevice = false
    /// True when config.toml did not set `on_device`; then `chooseOnDevice` turns it on for a model already installed.
    public var onDeviceUnset = true
    public var mlxModel = MLXModelChoice.recommended()
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
        if let v = try c.decodeIfPresent(Bool.self, forKey: .onDevice) { onDevice = v; onDeviceUnset = false }
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

    /// With no `on_device` in config.toml, the on-device model is on only when a model that fits `memory` is already
    /// installed: `mlxModel` when it is one, else the first such model in the catalog. A user who downloaded a model
    /// before keeps it, and on a new Mac nothing is used or downloaded.
    public mutating func chooseOnDevice(installed: (MLXModelChoice) -> Bool, memory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        guard onDeviceUnset else { return }
        let fits = MLXModelChoice.allCases.filter { installed($0) && memory >= $0.minMemory }
        if !fits.contains(mlxModel), let m = fits.first { mlxModel = m }
        onDevice = !fits.isEmpty
    }

    /// Below `MLXModelChoice.memoryFloor` the on-device model goes off. When `mlxModel` needs more than `memory`, it
    /// changes to the first installed model that fits; with none, to `MLXModelChoice.recommended(memory:)`, and the
    /// model goes off, so it is never on with no model. While the model was on, this gives one line that says so.
    public mutating func fitMemory(_ memory: UInt64, installed: (MLXModelChoice) -> Bool = { _ in false }) -> String? {
        guard MLXModelChoice.anyFits(memory: memory) else {
            defer { onDevice = false }
            return onDevice ? MLXModelChoice.notEnoughMemory : nil
        }
        guard memory < mlxModel.minMemory else { return nil }
        let want = mlxModel, wasOn = onDevice
        if let m = MLXModelChoice.allCases.first(where: { installed($0) && memory >= $0.minMemory }) {
            mlxModel = m
            return wasOn ? MLXModelChoice.memoryWarning(want, memory: memory) + " Sanketa uses \(m.displayName)." : nil
        }
        mlxModel = MLXModelChoice.recommended(memory: memory)
        onDevice = false
        return wasOn ? MLXModelChoice.memoryWarning(want, memory: memory)
            + " No model that fits is downloaded, so the on-device model is off." : nil
    }

    /// The variable to read the key from for this server: `api_key_env` when set, else `OPENAI_API_KEY` for
    /// api.openai.com only. nil: only a Keychain key saved for this host is sent.
    public func keyVariable(for baseURL: URL) -> String? {
        apiKeyEnv ?? (OpenAIModels.isOpenAI(baseURL) ? "OPENAI_API_KEY" : nil)
    }
}

/// `[vault]`: the vishalakshi vault that search reads, read-only. An empty `path` uses `VISHALAKSHI_VAULT`, then
/// `ABHYASA_VAULT`, then `~/.vishalakshi/vault.db`.
public struct VaultConfig: Codable, Equatable, Sendable {
    public var enabled = true
    public var path = ""
    /// the abhyasa web app, which shows a concept at `<learning_url>/c/<slug>`
    public var learningURL = "http://127.0.0.1:5077"

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, path, learningURL = "learning_url" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? path
        learningURL = try c.decodeIfPresent(String.self, forKey: .learningURL) ?? learningURL
    }

    public static let defaultPath = "~/.vishalakshi/vault.db"

    /// The vault file: `path`, else the first variable of `env` that is set, else `defaultPath`; `~` expanded.
    public func resolvedPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let p = [path, env["VISHALAKSHI_VAULT"] ?? "", env["ABHYASA_VAULT"] ?? ""].first { !$0.isEmpty } ?? Self.defaultPath
        return (p as NSString).expandingTildeInPath
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
    public var vault = VaultConfig()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case hotkey, terminals, pollInterval, tipRotateSeconds, translucency, coach, llm, vault
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
        vault = try c.decodeIfPresent(VaultConfig.self, forKey: .vault) ?? vault
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

    /// The config, why it did not load, and a note. A missing file gives defaults and no error; bad TOML gives defaults
    /// and a short message, such as `hotkey must be a string`. A `mlx_model` that needs more memory than `memory`
    /// changes to the model that fits, and the note says so: the file loaded, so that is not an error.
    /// `installed` tells if a model is downloaded, for a config with no `on_device` (see `LLMConfig.chooseOnDevice`).
    public static func load(_ url: URL, memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                            installed: (MLXModelChoice) -> Bool = { _ in false }) -> (config: Config, error: String?, note: String?) {
        var c = Config(), failure: String?
        if let data = try? Data(contentsOf: url) {
            do { c = try TOMLDecoder().decode(Config.self, from: data) }
            catch { failure = PackLint.describe(error, root: "") }
        }
        c.llm.chooseOnDevice(installed: installed, memory: memory)
        let note = c.llm.fitMemory(memory, installed: installed)
        return (c, failure, note)
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
