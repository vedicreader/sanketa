import AppKit
import SwiftUI
import SanketaCore
import SanketaSystem

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var search: SearchModel
    let field: SearchTextField
    let mark: NSView
    let grantAccessibility: () -> Void
    let pick: (Int) -> Void
    let clickLayer: (Int) -> Void
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var position = ScrollPosition(edge: .top)
    @State var fade = 1.0

    var showsList: Bool { search.query.isEmpty || model.listFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Passthrough(view: mark).frame(width: Brand.markPoints, height: Brand.markPoints)
                Breadcrumb(layers: model.context.layers, click: clickLayer)
            }
            .frame(height: Theme.topRow).padding(.horizontal, Theme.pad)
            SearchField(field: field).padding(.horizontal, Theme.pad - 2).padding(.top, Theme.fieldGap).padding(.bottom, 10)
            ScrollViewReader { proxy in
                PanelScroll(position: $position, offset: { model.scrollOffset = $0 }) {
                    VStack(alignment: .leading, spacing: Theme.sectionGap) {
                        if showsList { content } else { results }
                    }
                    .padding(.horizontal, Theme.pad - 6).padding(.bottom, Theme.pad)
                }
                .opacity(fade)
                // a new stack: back to where the user left it (the top when new), and a short fade with no slide
                .onChange(of: model.scrollToken) { _, _ in
                    position.scrollTo(y: model.scrollTarget)
                    guard !reduceMotion else { return }
                    fade = 0
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.12)) { fade = 1 } }
                }
                .onChange(of: model.selectedLayer) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
            if model.showsFooter { Footer(model: model, grant: grantAccessibility) }
        }
        // the top row sits in the title bar, so the safe area there would only add dead space
        .ignoresSafeArea(.container, edges: .top)
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

    /// Results use the list's grammar, on the panel's own tint: no box.
    var results: some View {
        ResultsList(results: search.results, selection: search.selection, prefix: search.prefix(for:), pick: pick, query: search.query)
    }
}

struct ResultsList: View {
    let results: [SearchItem]
    let selection: Int
    let prefix: (String) -> String?
    let pick: (Int) -> Void
    var query = ""

    static func noResult(_ q: String) -> String { "No result for \u{201C}\(q.trimmingCharacters(in: .whitespaces))\u{201D}." }
    static let noResultHelp = "Search finds keys and tips in all packs. Press esc to close."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                if i == 0 || results[i - 1].packID != r.packID {
                    Text(r.packName).font(Theme.header).foregroundStyle(Theme.secondary)
                        .padding(.top, i == 0 ? 0 : 8).padding(.leading, 6)
                }
                ResultRow(item: r, prefix: prefix(r.packID), selected: i == selection).onTapGesture { pick(i) }
            }
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.noResult(query)).font(Theme.text).foregroundStyle(.primary)
                    Text(Self.noResultHelp).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

/// One row, like the list: the action on the left and the keys on the right. A tip shows its snippet on a second
/// line, cut to one line. The selection is a saffron bar, with no fill.
struct ResultRow: View {
    let item: SearchItem
    var prefix: String?
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            RoundedRectangle(cornerRadius: 1).fill(selected ? Theme.accent : .clear).frame(width: 2.5, height: 14).padding(.trailing, 3.5)
            if item.kind == .key {
                Text(item.title).font(Theme.text).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 10)
                KeyChip(keys: item.detail, prefix: prefix).frame(minWidth: Theme.keyColumn, alignment: .trailing).layoutPriority(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Theme.text).foregroundStyle(.primary).lineLimit(1)
                    Text(item.detail).font(Theme.snippet).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, Theme.rowPad).padding(.trailing, 6)
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

extension EnvironmentValues {
    /// Draws the list as a clipped stack instead of a scroll view, for `ImageRenderer`, which does not draw scroll content.
    @Entry var flatList = false
}

struct PanelScroll<Content: View>: View {
    @Binding var position: ScrollPosition
    let offset: (CGFloat) -> Void
    @ViewBuilder var content: Content
    @Environment(\.flatList) var flat

    var body: some View {
        if flat {
            Color.clear.overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else {
            ScrollView { content }
                .scrollIndicators(.never)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in offset(y) }
        }
    }
}
