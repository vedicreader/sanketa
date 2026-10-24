import Foundation

/// Leela's live keymap over the bundled `leela` pack. Each entry's `command` is a Leela action id; its chord is
/// keys.json's `keys` override, else `_defaults`, else the bundled default. An empty chord hides the entry.
public enum LeelaKeymap {
    public static let packID = "leela"
    static let mods = ["mod": "⌘", "cmd": "⌘", "ctrl": "⌃", "alt": "⌥", "opt": "⌥", "shift": "⇧"]

    /// `$LEELA_KEYMAP` when set, else `~/.config/leela/keys.json` (the same lookup Leela uses).
    public static func defaultURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        env["LEELA_KEYMAP"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/leela/keys.json")
    }

    /// One Leela chord (`alt+shift+b`, `hyper+left`, `N`) in Mac symbols. Hyper (⌃⌥⇧⌘) shows as `hyperLabel`,
    /// a no-break space and the key, so the panel keeps it as one step.
    public static func render(_ chord: String, hyperLabel: String = "Caps") -> String {
        var parts = chord.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var base = parts.removeLast()
        if base.isEmpty, !parts.isEmpty, parts.last?.isEmpty == true { parts.removeLast(); base = "+" }   // `mod++`
        var set = Set<String>(), hyper = false
        for m in parts.map({ $0.lowercased() }) {
            if m == "hyper" { hyper = true } else if let s = mods[m] { set.insert(s) }
        }
        // Leela reads a single upper-case ASCII letter as shift + the letter
        if base.count == 1, let c = base.first, c.isASCII, c.isUppercase { set.insert("⇧"); base = base.lowercased() }
        guard hyper else { return KeyNotation.compose(set, base) }
        // composed with one modifier so letters upper-case like any modified key, then that modifier dropped
        return hyperLabel + "\u{a0}" + String(KeyNotation.compose(["⌘"], base).dropFirst())
    }

    /// `pack` with keys.json applied. `json` nil or unreadable gives Leela's defaults.
    public static func overlay(_ pack: Pack, json: Data?, hyperLabel: String = "Caps") -> Pack {
        let obj = json.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let defaults = obj["_defaults"] as? [String: Any] ?? [:]
        // current files keep overrides under "keys"; older ones are a flat action -> chord object
        let over = obj["keys"] as? [String: Any] ?? obj.filter { !$0.key.hasPrefix("_") }
        var p = pack
        p.keys = pack.keys.compactMap { e in
            guard let id = e.command else { return e }
            let chord = (over[id] as? String) ?? (defaults[id] as? String) ?? e.keys
            let alts = chord.split(whereSeparator: \.isWhitespace).map { render(String($0), hyperLabel: hyperLabel) }
            guard !alts.isEmpty else { return nil }
            var k = e
            k.keys = alts.joined(separator: " / ")
            return k
        }
        return p
    }

    /// Applies the keymap file at `url` (if any) to the library's `leela` pack; a file that isn't JSON is reported.
    public static func apply(to lib: inout PackLibrary, keysJSON url: URL?, hyperLabel: String = "Caps") {
        guard let pack = lib.packs[packID] else { return }
        let data = url.flatMap { try? Data(contentsOf: $0) }
        if let data, let url, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil {
            lib.errors.append(PackLoadError(file: url.path, message: "not a JSON object; using Leela's default keys"))
        }
        lib.packs[packID] = overlay(pack, json: data, hyperLabel: hyperLabel)
    }
}
