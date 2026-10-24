import SwiftUI
import SanketaCore

/// A key combo in Mac symbols: plain SF Mono, no box.
struct KeyChip: View {
    let keys: String
    var prefix: String?
    var dimmed = false

    var body: some View {
        Text(KeyNotation.display(keys, prefix: prefix))
            .font(Theme.keys).foregroundStyle(dimmed ? Theme.secondary : .primary)
            .fixedSize()
    }
}
