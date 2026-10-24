import SwiftUI
import SanketaCore

/// A key combo in Mac symbols, no box: symbols in SF Pro (SF Mono's ⌃ reads as a caret), letters in SF Mono,
/// a little air between glyphs and more between chord steps.
struct KeyChip: View {
    let keys: String
    var prefix: String?
    var dimmed = false

    var body: some View {
        KeyLabel(text: KeyNotation.display(keys, prefix: prefix))
            .foregroundStyle(dimmed ? Theme.secondary : .primary)
    }
}

struct KeyLabel: View {
    let text: String
    static let symbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "🌐", "←", "→", "↑", "↓", "↩", "⎋", "⌫", "⌦", "⇥"]
    static let glyphGap: CGFloat = 3, stepGap: CGFloat = 12

    /// `⌃⌥X` → ["⌃", "⌥", "X"]; runs of other characters (`PgUp`, `F6`) stay whole.
    static func tokens(_ step: Substring) -> [String] {
        var out = [String](), run = ""
        for c in step {
            if symbols.contains(c) {
                if !run.isEmpty { out.append(run); run = "" }
                out.append(String(c))
            } else { run.append(c) }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    var body: some View {
        HStack(spacing: Self.stepGap) {
            ForEach(Array(text.components(separatedBy: "  ").enumerated()), id: \.offset) { _, step in
                HStack(spacing: Self.glyphGap) {
                    ForEach(Array(Self.tokens(Substring(step)).enumerated()), id: \.offset) { _, t in
                        Text(t).font(Self.symbols.contains(t.first ?? " ") ? Theme.keySymbols : Theme.keys)
                    }
                }
            }
        }
        .fixedSize()
    }
}
