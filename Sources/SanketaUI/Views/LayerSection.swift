import AppKit
import SwiftUI
import SanketaCore

struct LayerSection: View {
    let data: LayerSectionData
    let collapsed: Bool
    var selected = false
    var folded: (RowGroup) -> Bool = { _ in false }
    var toggleGroup: (RowGroup) -> Void = { _ in }
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    Text(data.pack.name + (data.layer.host.map { " @ \($0)" } ?? "") + (data.layer.context.map { " · \($0)" } ?? ""))
                        .font(Theme.header)
                    Spacer()
                    if let p = data.pack.prefix {
                        HStack(spacing: 4) { Text("prefix").font(Theme.small); KeyLabel(text: KeyNotation.display(p), small: true) }
                    }
                }
                .foregroundStyle(Theme.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                ForEach(data.groups) { g in
                    let shut = folded(g)
                    if let n = g.name {
                        if g.folds {
                            // a folded group is one line: chevron, name and key count, an index of the layer
                            Button { toggleGroup(g) } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                                        .rotationEffect(.degrees(shut ? 0 : 90))
                                    Text(n).font(Theme.small)
                                    Spacer()
                                    if shut { Text("\(g.keys.count)").font(Theme.small).monospacedDigit() }
                                }
                                .foregroundStyle(Theme.secondary).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).padding(.top, 2)
                        } else {
                            Text(n).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 2)
                        }
                    }
                    if !shut { ForEach(Array(g.keys.enumerated()), id: \.offset) { _, k in
                        HStack(alignment: .firstTextBaseline) {
                            // disabled menu items stay listed, dimmed: their state changes with context
                            Text(k.action).font(Theme.text).foregroundStyle(k.enabled == false ? Theme.secondary : .primary).lineLimit(2)
                            Spacer(minLength: 10)
                            KeyChip(keys: k.keys, prefix: data.pack.prefix, dimmed: k.enabled == false)
                                .frame(minWidth: Theme.keyColumn, alignment: .trailing).layoutPriority(1)
                        }
                        .padding(.vertical, Theme.rowPad)
                    } }
                }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(selected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A program or shell with no pack: its name as a header and one line that says how to add a pack.
struct NoPackSection: View {
    let layer: Layer

    static func message(_ name: String) -> String { "No keys for \(name). Add a pack in ~/.config/sanketa/packs." }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Text(layer.name + (layer.host.map { " @ \($0)" } ?? "")).font(Theme.header).foregroundStyle(Theme.secondary)
            Text(Self.message(layer.name)).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }
}
