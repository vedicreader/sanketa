import SwiftUI
import SanketaCore

struct TipCard: View {
    let item: SearchItem
    var prefix: String?
    var copy: (String) -> Void = { _ in }
    let mark: (TipMark) -> Void
    @State var hover = false

    /// What the copy button copies: a key tip's keys as shown, else the snippet.
    static func copyText(_ item: SearchItem, prefix: String?) -> String {
        item.kind == .key ? KeyNotation.display(item.detail, prefix: prefix) : item.detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.packID == "coach" ? "better way" : "tip · \(item.packName)").font(Theme.header).foregroundStyle(Theme.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(Theme.text).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if item.kind == .key {
                        KeyChip(keys: item.detail, prefix: prefix).frame(minWidth: Theme.keyColumn, alignment: .trailing).layoutPriority(1)
                    }
                }
                if item.kind != .key { Text(item.detail).font(Theme.snippet).foregroundStyle(.primary).textSelection(.enabled) }
                if let e = item.explain, !e.isEmpty { Text(e).font(Theme.small).foregroundStyle(Theme.secondary) }
                HStack(spacing: 14) {
                    Button("I know this") { mark(.known) }
                    Button("Show less") { mark(.less) }
                }
                .buttonStyle(.plain).font(Theme.tiny).foregroundStyle(Theme.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .overlay(alignment: .topTrailing) {
            if hover { CopyButton { copy(Self.copyText(item, prefix: prefix)) }.offset(x: 13, y: 18) }
        }
    }
}
