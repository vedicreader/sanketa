import AppKit
import SwiftUI
import SanketaCore

struct LayerSection: View {
    let data: LayerSectionData
    let collapsed: Bool
    var selected = false
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(data.pack.name + (data.layer.host.map { " @ \($0)" } ?? "")).font(Theme.header)
                    Spacer()
                    if let p = data.pack.prefix { Text("prefix \(KeyNotation.display(p))").font(Theme.small) }
                }
                .foregroundStyle(Theme.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                ForEach(data.groups) { g in
                    if let n = g.name { Text(n).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 2) }
                    ForEach(Array(g.keys.enumerated()), id: \.offset) { _, k in
                        HStack(alignment: .firstTextBaseline) {
                            // disabled menu items stay listed, dimmed: their state changes with context
                            Text(k.action).font(Theme.text).foregroundStyle(k.enabled == false ? Theme.secondary : .primary).lineLimit(2)
                            Spacer(minLength: 10)
                            KeyChip(keys: k.keys, prefix: data.pack.prefix, dimmed: k.enabled == false)
                        }
                    }
                }
                if !data.pack.tips.isEmpty {
                    Text("Tips").font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 2)
                    ForEach(Array(data.pack.tips.enumerated()), id: \.offset) { TipRow(tip: $0.element) }
                }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
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
                Button { copy(tip.snippet) } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Copy")
            }
        }
    }
}

func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
