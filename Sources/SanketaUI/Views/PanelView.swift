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
    let clickLayer: (Int) -> Void
    @Environment(\.colorScheme) var scheme

    var showsList: Bool { search.query.isEmpty || model.listFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Breadcrumb(layers: model.context.layers, click: clickLayer).padding(.horizontal, Theme.pad)
            SearchField(field: field).padding(.horizontal, Theme.pad - 2)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.sectionGap) {
                        Color.clear.frame(height: 0).id("top")
                        if showsList { content } else { results }
                    }
                    .padding(.horizontal, Theme.pad - 6).padding(.bottom, Theme.pad)
                }
                .scrollIndicators(.never)
                .onChange(of: model.scrollToken) { _, _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: model.selectedLayer) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
            if model.showsFooter { Footer(model: model, grant: grantAccessibility) }
        }
        .padding(.top, Theme.topStrip)
        .frame(minWidth: 260, minHeight: 240)
        .background(Theme.tint(scheme == .dark).opacity(Theme.tintOpacity(model.translucency)))
    }

    @ViewBuilder var content: some View {
        ForEach(Array(model.blocks.enumerated()), id: \.element.id) { i, b in
            if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, 6) }
            switch b {
            case .tips:
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.tipCards.enumerated()), id: \.offset) { _, t in
                        TipCard(item: t, prefix: model.sections.first { $0.pack.id == t.packID }?.pack.prefix) { model.mark(t, $0) }
                    }
                }
                .padding(.horizontal, 6)
            case .section(let s):
                LayerSection(data: s, collapsed: model.collapsed.contains(s.id), selected: model.selectedLayer == s.id,
                             folded: { model.isFolded(s, $0) }, toggleGroup: { model.toggle(s, $0) }) { model.toggle(s.id) }
                    .id(s.id)
            case .noPack(let l, _):
                NoPackSection(layer: l)
            }
        }
        if model.blocks.isEmpty {
            Text("No keys for this app.").font(Theme.small).foregroundStyle(Theme.secondary).padding(.horizontal, 6)
        }
    }

    /// Results always sit on their own dimmed backing so they read over terminal text.
    var results: some View {
        ResultsList(results: search.results, selection: search.selection, prefix: search.prefix(for:), pick: pick)
            .padding(6)
            .background(Theme.tint(scheme == .dark).opacity(Theme.resultsBackingOpacity), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ResultsList: View {
    let results: [SearchItem]
    let selection: Int
    let prefix: (String) -> String?
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                ResultRow(item: r, prefix: prefix(r.packID), selected: i == selection).onTapGesture { pick(i) }
            }
            if results.isEmpty { Text("No results.").font(Theme.small).foregroundStyle(Theme.secondary).padding(6) }
        }
    }
}

struct ResultRow: View {
    let item: SearchItem
    var prefix: String?
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(selected ? Theme.accent : .clear).frame(width: 2.5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(Theme.text).foregroundStyle(.primary).lineLimit(2)
                    Spacer(minLength: 8)
                    Text(item.packName).font(Theme.header).foregroundStyle(Theme.secondary)
                }
                if item.kind == .key { KeyChip(keys: item.detail, prefix: prefix) }
                else { Text(item.detail).font(Theme.snippet).foregroundStyle(.primary).lineLimit(3) }
            }
        }
        .padding(.vertical, 5 + Theme.rowPad).padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Layers as plain text, innermost first, joined by ` › `; clicking one jumps to its section.
struct Breadcrumb: View {
    let layers: [Layer]
    let click: (Int) -> Void

    /// `ssh host`, `name@host`, or `name · context` when the window title picks a pack context
    static func label(_ l: Layer) -> String {
        l.kind == .remote ? "ssh \(l.name)" : l.name + (l.host.map { "@\($0)" } ?? "") + (l.context.map { " · \($0)" } ?? "")
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(layers.enumerated()), id: \.offset) { i, l in
                if i > 0 { Text(" › ").foregroundStyle(Theme.secondary) }
                Button { click(i) } label: {
                    Text(Self.label(l))
                        .fontWeight(i == 0 ? .semibold : .medium)
                        .foregroundStyle(i == 0 ? Theme.primary : Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.small)
        .lineLimit(1)
    }
}

struct Footer: View {
    @ObservedObject var model: PanelModel
    let grant: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.needsAccessibility {
                Button(action: grant) { Text("Allow Accessibility to show menu keys").underline() }
                    .buttonStyle(.plain).foregroundStyle(.primary)
            }
            if !model.packErrors.isEmpty {
                Text("\(model.packErrors.count) pack file\(model.packErrors.count == 1 ? "" : "s") did not load. Point to this line to see why.")
                    .help(model.packErrors.map { "\(($0.file as NSString).lastPathComponent): \($0.message)" }.joined(separator: "\n"))
            }
            if let h = model.hotkeyConflict {
                Text("Sanketa cannot use \(Theme.display(hotkey: h)). Set hotkey in ~/.config/sanketa/config.toml.")
            }
        }
        .font(Theme.small).foregroundStyle(Theme.secondary)
        .padding(.horizontal, Theme.pad).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}
