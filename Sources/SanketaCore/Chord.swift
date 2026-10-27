import Foundation

/// A modifier key; the raw value is the Mac symbol and the order is ⌃⌥⇧⌘.
public enum Modifier: String, CaseIterable, Comparable, Sendable {
    case ctrl = "⌃", opt = "⌥", shift = "⇧", cmd = "⌘"
    public static func < (a: Modifier, b: Modifier) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// A key combo in one canonical form, read from and written to AeroSpace, Leela and Sanketa styles.
public struct Chord: Hashable, Sendable {
    public var mods: Set<Modifier>
    public var key: String

    public init(mods: Set<Modifier>, key: String) { self.mods = mods; self.key = key }

    public var isHyper: Bool { mods.count == Modifier.allCases.count }

    /// AeroSpace key names; the canonical key is the value.
    static let aeroNames = ["leftSquareBracket": "[", "rightSquareBracket": "]", "minus": "-", "equal": "=", "backtick": "`",
                            "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
                            "pageUp": "pageup", "pageDown": "pagedown"]
    /// Other spellings (Leela names, display glyphs) of canonical keys.
    static let aliases = ["return": "enter", "↩": "enter", "escape": "esc", "⎋": "esc", "⌫": "backspace", "bspace": "backspace",
                          "⇥": "tab", "↑": "up", "↓": "down", "←": "left", "→": "right", "pgup": "pageup", "pgdn": "pagedown",
                          "⇞": "pageup", "⇟": "pagedown", "del": "delete", "⌦": "delete"]
    static let canonical = aeroNames.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        .merging(aliases) { a, _ in a }
    static let aeroText = Dictionary(uniqueKeysWithValues: aeroNames.map { ($1, $0) })
    static let aeroOrder: [(Modifier, String)] = [(.cmd, "cmd"), (.opt, "alt"), (.ctrl, "ctrl"), (.shift, "shift")]
    static let leelaMods: [String: Modifier] = ["ctrl": .ctrl, "control": .ctrl, "alt": .opt, "opt": .opt, "option": .opt,
                                                "shift": .shift, "cmd": .cmd, "command": .cmd, "mod": .cmd]

    /// Canonical key for any spelling; single letters fold to lower case and unknown names stay as is.
    static func norm(_ k: String) -> String {
        canonical[k.lowercased()] ?? (k.count == 1 || (k.first?.lowercased() == "f" && Int(k.dropFirst()) != nil) ? k.lowercased() : k)
    }

    public static func aerospace(_ s: String) -> Chord? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !key.isEmpty else { return nil }
        var mods = Set<Modifier>()
        for m in parts.dropLast() {
            guard let mod = leelaMods[m.lowercased()], m.lowercased() != "mod" else { return nil }
            mods.insert(mod)
        }
        return Chord(mods: mods, key: norm(key))
    }

    public static func leela(_ s: String) -> Chord? {
        var parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var key = parts.removeLast()
        if key.isEmpty, parts.last?.isEmpty == true { parts.removeLast(); key = "+" }   // `mod++`
        guard !key.isEmpty else { return nil }
        var mods = Set<Modifier>()
        // Leela reads a single upper-case ASCII letter as shift + the letter
        if key.count == 1, let c = key.first, c.isASCII, c.isUppercase { mods.insert(.shift) }
        for m in parts.map({ $0.lowercased() }) {
            if m == "hyper" { mods.formUnion(Modifier.allCases) } else if let mod = leelaMods[m] { mods.insert(mod) } else { return nil }
        }
        return Chord(mods: mods, key: norm(key))
    }

    public static func sanketa(_ s: String, hyperLabel: String = "Caps") -> Chord? {
        var rest = Substring(s), mods = Set<Modifier>()
        if rest.hasPrefix(hyperLabel + "\u{a0}") { rest = rest.dropFirst(hyperLabel.count + 1); mods = Set(Modifier.allCases) }
        while rest.count > 1, let c = rest.first, let m = Modifier(rawValue: String(c)) { mods.insert(m); rest = rest.dropFirst() }
        return rest.isEmpty ? nil : Chord(mods: mods, key: norm(String(rest)))
    }

    public func display(hyperLabel: String = "Caps") -> String {
        guard isHyper else { return KeyNotation.compose(Set(mods.map(\.rawValue)), key) }
        // composed with one modifier so letters upper-case like any modified key, then that modifier dropped
        return hyperLabel + "\u{a0}" + String(KeyNotation.compose(["⌘"], key).dropFirst())
    }

    public var aerospaceText: String {
        (Self.aeroOrder.filter { mods.contains($0.0) }.map(\.1) + [Self.aeroText[key] ?? key]).joined(separator: "-")
    }

    public var leelaText: String {
        let names: [Modifier: String] = [.ctrl: "ctrl", .opt: "alt", .shift: "shift", .cmd: "cmd"]
        return (isHyper ? ["hyper"] : mods.sorted().map { names[$0]! }).joined(separator: "+") + (mods.isEmpty ? "" : "+") + key
    }
}
