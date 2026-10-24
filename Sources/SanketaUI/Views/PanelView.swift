import AppKit
import SwiftUI
import SanketaCore
import SanketaSystem

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var search: SearchModel
    let field: SearchTextField
    let grantAccessibility: () -> Void
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Breadcrumb(layers: model.context.layers).padding(.horizontal, Theme.pad)
            SearchField(field: field).padding(.horizontal, Theme.pad - 2)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    if search.query.isEmpty { content } else { results }
                }
                .padding(.horizontal, Theme.pad).padding(.bottom, Theme.pad)
            }
            .scrollIndicators(.never)
            if model.showsFooter { Footer(model: model, grant: grantAccessibility) }
        }
        .padding(.top, 26)
        .frame(minWidth: 260, minHeight: 240)
    }

    @ViewBuilder var content: some View {
        if let t = model.tip {
            TipCard(item: t, prefix: model.sections.first { $0.pack.id == t.packID }?.pack.prefix) { model.mark($0) }
        }
        ForEach(model.sections) { s in
            LayerSection(data: s, collapsed: model.collapsed.contains(s.id)) { model.toggle(s.id) }
        }
        if model.sections.isEmpty && model.tip == nil {
            Text("No shortcuts for this app yet.").font(Theme.small).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var results: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(search.results.enumerated()), id: \.element.id) { i, r in
                ResultRow(item: r, selected: i == search.selection).onTapGesture { pick(i) }
            }
            if search.results.isEmpty { Text("No matches").font(Theme.small).foregroundStyle(.secondary) }
        }
    }
}

struct ResultRow: View {
    let item: SearchItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(Theme.text).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 8)
                Text(item.packName).font(Theme.header).foregroundStyle(.secondary)
            }
            if item.kind == .key { KeyChip(keys: item.detail) }
            else { Text(item.detail).font(Theme.snippet).foregroundStyle(.primary).lineLimit(3) }
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Theme.accent : Theme.hairline.opacity(0.6),
                                                               lineWidth: selected ? 1.5 : 0.5))
        .contentShape(Rectangle())
    }
}

/// Layer chips, innermost first; remote layers carry a host chip.
struct Breadcrumb: View {
    let layers: [Layer]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Text("‹").font(Theme.small).foregroundStyle(.secondary) }
                HStack(spacing: 3) {
                    Text(l.kind == .remote ? "ssh" : l.name)
                    if let h = l.host { Text(h).foregroundStyle(Theme.accent) }
                }
                .font(Theme.small.weight(i == 0 ? .semibold : .regular))
                .foregroundStyle(i == 0 ? .primary : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 2.5)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(i == 0 ? Theme.accent : Theme.hairline, lineWidth: i == 0 ? 1 : 0.5))
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }
}

struct Footer: View {
    @ObservedObject var model: PanelModel
    let grant: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.needsAccessibility {
                Button("Grant Accessibility to read menu shortcuts", action: grant).buttonStyle(.plain).foregroundStyle(Theme.accent)
            }
            if !model.packErrors.isEmpty {
                Text("\(model.packErrors.count) pack file\(model.packErrors.count == 1 ? "" : "s") failed to load")
                    .help(model.packErrors.map { "\(($0.file as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n"))
            }
            if let h = model.hotkeyConflict {
                Text("\(Theme.display(hotkey: h)) isn't available. Set `hotkey` in ~/.config/sanketa/config.toml.")
            }
        }
        .font(Theme.small).foregroundStyle(.secondary)
        .padding(.horizontal, Theme.pad).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}
