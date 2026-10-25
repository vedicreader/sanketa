import SwiftUI
import SanketaCore

struct TipCard: View {
    let item: SearchItem
    var prefix: String?
    var copy: (String) -> Void = { _ in }
    let mark: (TipMark) -> Void
    @State var hover = false

    /// What the copy button copies: the snippet, or a key tip's command.
    static func copyText(_ item: SearchItem) -> String? { item.copyText }

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
        .padding(.trailing, CopyButton.slot)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // inside the card's frame, on the line under the header, so the pointer stays in the hover area
        .overlay(alignment: .topTrailing) {
            if hover, let t = Self.copyText(item) { CopyButton { copy(t) }.padding(.top, 18) }
        }
        .onHover { hover = $0 }
    }
}
