import SwiftUI

/// A key combo as mono chips, one per space-separated stroke; `prefix` shows the pack's prefix with an accent border.
struct KeyChip: View {
    let keys: String
    var prefix: String?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.split(separator: " ").enumerated()), id: \.offset) { _, k in
                let isPrefix = k == "prefix"
                Text(isPrefix ? (prefix ?? "prefix") : String(k))
                    .font(Theme.mono)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(isPrefix ? Theme.accent : Theme.hairline, lineWidth: isPrefix ? 1 : 0.5))
            }
        }
        .fixedSize()
    }
}
