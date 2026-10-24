import Foundation

/// Renders tmux/emacs (`C-b`, `M-Up`) and `ctrl+r` notation as Mac key symbols.
public enum KeyNotation {
    static let order = ["⌃", "⌥", "⇧", "⌘"]
    static let tmuxMods: [Character: String] = ["C": "⌃", "M": "⌥", "S": "⇧"]
    static let plusMods = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
    /// Arrows, ↩ and ⌫ stay symbols; keys with obscure glyphs (⎋ ⇥ ⌦ ⇞ ⇟) show as short lowercase words.
    static let named = ["up": "↑", "down": "↓", "left": "←", "right": "→", "enter": "↩", "return": "↩",
                        "escape": "esc", "esc": "esc", "⎋": "esc", "space": "space", "bspace": "⌫", "backspace": "⌫",
                        "tab": "tab", "⇥": "tab", "ppage": "pgup", "pageup": "pgup", "pgup": "pgup", "⇞": "pgup",
                        "npage": "pgdn", "pagedown": "pgdn", "pgdn": "pgdn", "⇟": "pgdn",
                        "dc": "del", "delete": "del", "del": "del", "⌦": "del", "ic": "ins", "insert": "ins",
                        "home": "home", "end": "end"]

    /// Steps of a chord are joined by two spaces; `prefix` becomes the pack's prefix.
    public static func display(_ keys: String, prefix: String? = nil) -> String {
        keys.split(separator: " ").map { t in
            t == "prefix" ? prefix.map { display($0) } ?? "prefix" : step(String(t))
        }.joined(separator: "  ")
    }

    static func step(_ t: String) -> String {
        var mods = Set<String>(), rest = Substring(t)
        while rest.count > 2, let m = tmuxMods[rest.first!], rest.dropFirst().first == "-" {
            mods.insert(m); rest = rest.dropFirst(2)
        }
        if mods.isEmpty, t.count > 1, t.contains("+") {
            let parts = t.split(separator: "+", omittingEmptySubsequences: false)
            let ms = parts.dropLast().compactMap { plusMods[$0.lowercased()] }
            if ms.count == parts.count - 1, let last = parts.last, !last.isEmpty { mods = Set(ms); rest = last }
        }
        return compose(mods, String(rest))
    }

    static func compose(_ mods: Set<String>, _ key: String) -> String {
        let parsed = mods
        var mods = mods, key = key
        // already in Mac symbols (`⌥PgUp`, `⇧⌘S`): peel the modifiers so the key is normalised and the order fixed
        while key.count > 1, let c = key.first, order.contains(String(c)) { mods.insert(String(c)); key.removeFirst() }
        if key.lowercased() == "btab" { mods.insert("⇧"); key = "tab" }
        var k = named[key.lowercased()] ?? key
        if key.count > 1, key.first == "f" || key.first == "F", Int(key.dropFirst()) != nil { k = key.uppercased() }   // f5 → F5
        if !mods.isEmpty, key.count == 1, let c = key.first, c.isASCII, c.isLetter {
            if c.isUppercase, parsed.contains("⌥") || parsed.contains("⌘") { mods.insert("⇧") }   // M-B is meta+shift+b; C-B is C-b
            k = key.uppercased()
        }
        return order.filter(mods.contains).joined() + k
    }
}
