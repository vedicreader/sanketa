import SwiftUI
import SanketaCore

struct TipCard: View {
    let item: SearchItem
    var prefix: String?
    let mark: (TipMark) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 5) {
                Text("tip · \(item.packName)").font(Theme.header).foregroundStyle(Theme.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(Theme.text).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if item.kind == .key { KeyChip(keys: item.detail, prefix: prefix) }
                }
                if item.kind != .key { Text(item.detail).font(Theme.snippet).foregroundStyle(.primary).textSelection(.enabled) }
                if let e = item.explain, !e.isEmpty { Text(e).font(Theme.small).foregroundStyle(Theme.secondary) }
                HStack(spacing: 14) {
                    Button("I know this") { mark(.known) }
                    Button("Show less") { mark(.less) }
                }
                .buttonStyle(.plain).font(Theme.small).foregroundStyle(.primary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
