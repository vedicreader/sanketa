import Foundation
import Carbon.HIToolbox
import TOMLDecoder

/// How much of what's behind the panel shows through; `low` dims most.
public enum Translucency: String, Codable, CaseIterable { case low, medium, high }

public struct Config: Codable, Equatable {
    public var hotkey = "ctrl+opt+k"
    public var terminals = ["app.conterm.Conterm", "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "fun.tw93.kaku"]
    public var pollInterval = 1.0
    public var tipRotateSeconds = 120.0
    public var translucency = Translucency.medium
    /// How Leela's Hyper (⌃⌥⇧⌘) shows in the panel; Caps Lock sends Hyper on the author's Mac.
    public var hyperLabel = "Caps"

    public init() {}

    enum CodingKeys: String, CodingKey {
        case hotkey, terminals, pollInterval, tipRotateSeconds, translucency
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
        translucency = (try? c.decodeIfPresent(String.self, forKey: .translucency)).flatMap { $0.flatMap(Translucency.init) } ?? .medium
    }

    /// `text` with top-level `key = value` replaced, or inserted before the first table; other lines kept.
    public static func setting(_ key: String, _ value: String, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        let new = "\(key) = \(value)"
        if let i = lines[..<firstTable].firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix(key) && t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) { lines[i] = new }
        else { lines.insert(new, at: firstTable) }
        return lines.joined(separator: "\n")
    }

    /// Persists one top-level key into the config file, creating it if needed.
    public static func save(_ key: String, _ value: String, to url: URL) throws {
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setting(key, value, in: old).write(to: url, atomically: true, encoding: .utf8)
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
