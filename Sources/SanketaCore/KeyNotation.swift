import Foundation

/// Renders tmux/emacs (`C-b`, `M-Up`) and `ctrl+r` notation as Mac key symbols.
public enum KeyNotation {
    static let order = ["⌃", "⌥", "⇧", "⌘"]
    static let tmuxMods: [Character: String] = ["C": "⌃", "M": "⌥", "S": "⇧"]
    static let plusMods = ["ctrl": "⌃", "control": "⌃", "opt": "⌥", "option": "⌥", "alt": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
    static let named = ["up": "↑", "down": "↓", "left": "←", "right": "→", "enter": "↩", "return": "↩", "escape": "⎋", "esc": "⎋",
                        "space": "Space", "bspace": "⌫", "backspace": "⌫", "tab": "⇥", "btab": "⇧⇥", "ppage": "PgUp",
                        "pageup": "PgUp", "npage": "PgDn", "pagedown": "PgDn", "dc": "⌦", "delete": "⌦", "ic": "Ins",
                        "home": "Home", "end": "End"]

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
        var mods = mods
        var k = key.count > 1 ? named[key.lowercased()] ?? key : key
        if !mods.isEmpty, key.count == 1, let c = key.first, c.isLetter {
            if c.isUppercase, mods.contains("⌥") || mods.contains("⌘") { mods.insert("⇧") }   // M-B is meta+shift+b; C-B is C-b
            k = key.uppercased()
        }
        return order.filter(mods.contains).joined() + k
    }
}
