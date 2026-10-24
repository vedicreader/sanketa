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

/// `small` is for inline use next to `Theme.small` text, such as a section header's prefix.
struct KeyLabel: View {
    let text: String
    var small = false
    static let symbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "🌐", "←", "→", "↑", "↓", "↩", "⌫"]
    static let glyphGap: CGFloat = 2, stepGap: CGFloat = 8

    /// `⌃⌥X` → ["⌃", "⌥", "X"]; runs of other characters (`esc`, `pgup`, `F6`) stay whole.
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
        let scale: CGFloat = small ? 0.8 : 1
        HStack(spacing: Self.stepGap * scale) {
            ForEach(Array(text.components(separatedBy: "  ").enumerated()), id: \.offset) { _, step in
                HStack(spacing: Self.glyphGap * scale) {
                    ForEach(Array(Self.tokens(Substring(step)).enumerated()), id: \.offset) { _, t in
                        Text(t).font(Self.symbols.contains(t.first ?? " ") ? (small ? Theme.keySymbolsSmall : Theme.keySymbols)
                                                                           : (small ? Theme.keysSmall : Theme.keys))
                    }
                }
            }
        }
        .fixedSize()
    }
}
