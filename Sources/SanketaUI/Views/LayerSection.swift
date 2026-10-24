import AppKit
import SwiftUI
import SanketaCore

struct LayerSection: View {
    let data: LayerSectionData
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(data.pack.name).font(Theme.header).foregroundStyle(.primary)
                    if let h = data.layer.host { Text(h).font(Theme.small).foregroundStyle(Theme.accent) }
                    Spacer()
                    if let p = data.pack.prefix { Text("prefix \(p)").font(Theme.snippet).foregroundStyle(.secondary) }
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                Divider().padding(.bottom, 2)
                ForEach(data.groups) { g in
                    if let n = g.name { Text(n).font(Theme.small).foregroundStyle(.secondary).padding(.top, 3) }
                    ForEach(g.keys, id: \.self) { k in
                        HStack(alignment: .firstTextBaseline) {
                            Text(k.action).font(Theme.text).foregroundStyle(.primary).lineLimit(2)
                            Spacer(minLength: 8)
                            KeyChip(keys: k.keys, prefix: data.pack.prefix)
                        }
                    }
                }
                if !data.pack.tips.isEmpty {
                    Text("Tips").font(Theme.small).foregroundStyle(.secondary).padding(.top, 3)
                    ForEach(data.pack.tips, id: \.self) { TipRow(tip: $0) }
                }
            }
        }
        .card()
    }
}

extension View {
    /// Subtle translucent backing so rows stay legible over busy backgrounds while the panel edges stay clear.
    func card() -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }
}

struct TipRow: View {
    let tip: Tip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tip.title).font(Theme.text).foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline) {
                Text(tip.snippet).font(Theme.snippet).foregroundStyle(.primary).textSelection(.enabled).lineLimit(3)
                Spacer(minLength: 6)
                Button { copy(tip.snippet) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
            }
        }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
