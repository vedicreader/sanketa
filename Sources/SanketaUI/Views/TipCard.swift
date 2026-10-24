import SwiftUI
import SanketaCore

struct TipCard: View {
    let item: SearchItem
    var prefix: String?
    let mark: (TipMark) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("tip · \(item.packName)").font(Theme.header).foregroundStyle(Theme.accent)
                Spacer()
            }
            Text(item.title).font(Theme.text.weight(.semibold)).foregroundStyle(.primary)
            if item.kind == .key { KeyChip(keys: item.detail, prefix: prefix) }
            else { Text(item.detail).font(Theme.snippet).foregroundStyle(.primary).textSelection(.enabled) }
            if let e = item.explain, !e.isEmpty { Text(e).font(Theme.small).foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                Button("I know this") { mark(.known) }
                Button("Show less") { mark(.less) }
            }
            .buttonStyle(.plain).font(Theme.small).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.cardRadius, bottomLeadingRadius: Theme.cardRadius)
                .fill(Theme.accent).frame(width: 3)
        }
    }
}
