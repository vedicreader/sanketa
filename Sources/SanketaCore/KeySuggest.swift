import Foundation

/// Where keys sit on an ANSI keyboard, in key-width units, and which the left hand reaches.
public enum KeyMap {
    public static let position: [String: (row: Int, col: Double)] = {
        let rows = ["`1234567890-=", "qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./"], offsets = [0, 0.5, 0.75, 1.25]
        var p = [String: (row: Int, col: Double)]()
        for (r, keys) in rows.enumerated() { for (i, k) in keys.enumerated() { p[String(k)] = (r, Double(i) + offsets[r]) } }
        return p
    }()
    public static let leftHand = Set("`12345qwertasdfgzxcvb".map(String.init) + ["tab"])
}

public struct Suggestion: Equatable, Sendable {
    public var chord: Chord
    public var score: Double
    public var reason: String
}

public enum KeySuggest {
    static func distance(_ a: String, _ b: String) -> Double? {
        guard let p = KeyMap.position[a], let q = KeyMap.position[b] else { return nil }
        let dr = Double(p.row - q.row), dc = p.col - q.col
        return (dr * dr + dc * dc).squareRoot()
    }

    /// The best free chords with the same modifiers, scored by nearness to partner keys, hand and a mnemonic letter.
    public static func suggest(action: String, mods: Set<Modifier>, partners: [Chord], used: Set<Chord>, hyperLabel: String, max: Int = 3) -> [Suggestion] {
        let words = action.lowercased().split { !$0.isLetter }.map(String.init)
        let order = KeyMap.position.sorted { ($0.value.row, $0.value.col) < ($1.value.row, $1.value.col) }.map(\.key)
        let all: [Suggestion] = order.compactMap { k in
            let chord = Chord(mods: mods, key: k)
            guard !used.contains(chord) else { return nil }
            let near = partners.filter { (distance(k, $0.key) ?? .infinity) <= 1.5 }
            var score = 4.0, why = ["free"]
            if let d = partners.compactMap({ distance(k, $0.key) }).min() { score += 3 * (1 - Swift.min(d, 4) / 4) }
            if !near.isEmpty {
                let names = near.map { $0.display(hyperLabel: hyperLabel) }
                why.append("next to your " + (names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]))
            }
            if KeyMap.leftHand.contains(k) { score += 2; why.append("left hand") }
            if let w = words.first(where: { $0.first.map(String.init) == k }) { score += 1.5; why.append("the first letter of \"\(w)\"") }
            return Suggestion(chord: chord, score: score, reason: why.joined(separator: ", "))
        }
        return Array(all.enumerated().sorted { ($1.element.score, $0.offset) < ($0.element.score, $1.offset) }.prefix(max).map(\.element))
    }
}
