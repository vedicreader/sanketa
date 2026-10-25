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
    var openFile: (String) -> Void = { _ in }
    var makePack: (Layer) -> Void = { _ in }
    /// the open button of a vault result: opens it and ends search
    var openResult: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) var scheme
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State var position = ScrollPosition(edge: .top)
    @State var fade = 1.0
    @Environment(\.imageRendering) var imageRendering

    var showsList: Bool { search.query.isEmpty || model.listFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let m = Brand.mark() {
                    Image(nsImage: m).renderingMode(.template).resizable().foregroundStyle(Theme.secondary)
                        .frame(width: Brand.markPoints, height: Brand.markPoints).allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                Breadcrumb(layers: model.context.layers, focused: model.focusedLayerIndex, click: clickLayer)
            }
            .frame(height: Theme.topRow).padding(.horizontal, Theme.pad)
            Group {
                // ImageRenderer cannot draw AppKit views: a clear slot of the field's height, for the render test to fill
                if imageRendering { Color.clear.frame(height: field.intrinsicContentSize.height) } else { SearchField(field: field) }
            }
            .padding(.horizontal, Theme.pad - 2).padding(.top, Theme.fieldGap).padding(.bottom, 10)
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
                    // one run-loop turn later, after the new stack's layout, so the offset is not clamped to the old height
                    let y = model.scrollTarget
                    DispatchQueue.main.async { position.scrollTo(y: y) }
                    guard !reduceMotion else { return }
                    fade = 0
                    DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.12)) { fade = 1 } }
                }
                .onChange(of: model.selectedLayer) { _, id in
                    if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
            if model.showsFooter { Footer(model: model, grant: grantAccessibility, open: openFile) }
        }
        .overlay(alignment: .bottom) { if let t = model.toast { Toast(text: t) } }
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
                        TipCard(item: t, prefix: model.sections.first { $0.pack.id == t.packID }?.pack.prefix, copy: { model.copy($0) }) { model.mark(t, $0) }
                    }
                }
                .padding(.horizontal, 6)
            case .section(let s):
                LayerSection(data: s, collapsed: model.collapsed.contains(s.id), selected: model.selectedLayer == s.id,
                             showsName: model.showsSectionNames,
                             folded: { model.isFolded(s, $0) }, toggleGroup: { model.toggle(s, $0) },
                             expandedRow: model.expandedRow, toggleRow: { model.toggleRow($0) }, copy: { model.copy($0) }) { model.toggle(s.id) }
                    .id(s.id)
            case .noPack(let l, _):
                NoPackSection(layer: l, makePack: makePack)
            case .makePack(let l, _):
                MakePackLink(layer: l, makePack: makePack)
            }
        }
        if model.blocks.isEmpty {
            Text("No keys for this app.").font(Theme.small).foregroundStyle(Theme.secondary).padding(.horizontal, 6)
        }
    }

    /// Results use the list's grammar, on the panel's own tint: no box.
    var results: some View {
        ResultsList(results: search.results, selection: search.selection, prefix: search.prefix(for:), pick: pick, query: search.query,
                    picked: search.picked, note: search.note, expanded: search.expanded, copy: { model.copy($0) },
                    openResult: openResult, saveHint: search.canSave ? SearchModel.saveHint : nil)
    }
}

struct ResultsList: View {
    let results: [SearchItem]
    let selection: Int
    let prefix: (String) -> String?
    let pick: (Int) -> Void
    var query = ""
    /// ids the model chose: a small saffron dot
    var picked: Set<String> = []
    /// one muted line under the results
    var note: String?
    /// the result that shows all its text
    var expanded: String?
    var copy: (String) -> Void = { _ in }
    var openResult: (Int) -> Void = { _ in }
    /// the keys that save to the vault: one muted line at the end
    var saveHint: String?

    static func noResult(_ q: String) -> String { "No result for \u{201C}\(q.trimmingCharacters(in: .whitespaces))\u{201D}." }
    static let noResultHelp = "Search finds keys and tips in all packs. Press esc to close."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            ForEach(Array(results.enumerated()), id: \.offset) { i, r in
                if i == 0 || results[i - 1].packID != r.packID {
                    Text(r.packName).font(Theme.header).foregroundStyle(Theme.secondary)
                        .padding(.top, i == 0 ? 0 : 8).padding(.leading, 6)
                }
                ResultRow(item: r, prefix: prefix(r.packID), selected: i == selection, picked: picked.contains(r.id),
                          expanded: expanded == r.id, toggle: { pick(i) }, copy: copy, openTarget: { openResult(i) })
            }
            if results.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.noResult(query)).font(Theme.text).foregroundStyle(.primary)
                    Text(Self.noResultHelp).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6)
            }
            if let note {
                Text(note).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(2).padding(.top, 6).padding(.horizontal, 6)
            }
            if let saveHint {
                Text(saveHint).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1).padding(.top, 6).padding(.horizontal, 6)
            }
        }
    }
}

/// One row, like the list: the action on the left and the keys on the right. A tip shows its snippet on a second
/// line, cut to one line. The selection is a saffron bar, with no fill. A click shows all the text, with a key's
/// command; on hover, a copy button copies the snippet or command, and a tooltip gives the full text. A vault result
/// shows its shelf's heading and a snippet in text type; when it has a target, an open button takes the copy button's
/// place.
struct ResultRow: View {
    let item: SearchItem
    var prefix: String?
    let selected: Bool
    var picked = false
    var expanded = false
    var toggle: () -> Void = {}
    var copy: (String) -> Void = { _ in }
    var openTarget: () -> Void = {}
    @State var hover = false

    var full: String {
        [item.title, item.kind == .key ? KeyNotation.display(item.detail, prefix: prefix) : item.detail, item.command, item.explain]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            RoundedRectangle(cornerRadius: 1).fill(selected ? Theme.accent : .clear).frame(width: 2.5, height: 14).padding(.trailing, 3.5)
            if picked {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).padding(.trailing, 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityLabel("Chosen by the model")
            }
            VStack(alignment: .leading, spacing: 2) {
                if item.kind == .key {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(item.title).font(Theme.text).foregroundStyle(.primary)
                            .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: expanded)
                        Spacer(minLength: 10)
                        KeyChip(keys: item.detail, prefix: prefix).frame(minWidth: Theme.keyColumn, alignment: .trailing).layoutPriority(1)
                    }
                    if expanded, let c = item.command, c != item.title {
                        Text(c).font(Theme.snippet).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(item.title).font(Theme.text).foregroundStyle(.primary)
                        .lineLimit(expanded ? nil : 1).fixedSize(horizontal: false, vertical: expanded)
                    Text(item.detail).font(item.kind == .vault ? Theme.small : Theme.snippet).foregroundStyle(expanded ? .primary : Theme.secondary)
                        .lineLimit(expanded ? nil : 1).truncationMode(.tail).fixedSize(horizontal: false, vertical: expanded)
                        .textSelection(.enabled)
                    if expanded, let e = item.explain, !e.isEmpty {
                        Text(e).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if selected, let h = SearchModel.keyHint(item) {
                        Text(h).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1).padding(.top, 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.rowPad)
        // a slot for the copy button inside the row, so the pointer stays in the hover area on its way to the button
        .padding(.trailing, CopyButton.slot)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .overlay(alignment: .topTrailing) {
            if hover, item.open != nil { OpenButton(action: openTarget).padding(.top, Theme.rowPad) }
            else if hover, let t = item.copyText { CopyButton { copy(t) }.padding(.top, Theme.rowPad) }
        }
        .onHover { hover = $0 }
        .help(full)
    }
}

/// The open button of a vault result, in the copy button's slot and style.
struct OpenButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.forward").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary)
                .frame(width: 12, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open")
        .accessibilityLabel("Open")
    }
}

/// Layers as plain text, innermost first, joined by ` › `; clicking one jumps to its section.
/// When the row is too narrow, the outer crumbs are cut first, from the terminal end; the tool in front is never cut.
struct Breadcrumb: View {
    let layers: [Layer]
    /// the layer whose section has keyboard focus; its crumb is semibold
    var focused: Int?
    let click: (Int) -> Void

    /// `ssh host`, or `name · context` when the window title picks a pack context. The host shows only on the
    /// `ssh` crumb; the section headers keep `@ host`.
    static func label(_ l: Layer) -> String {
        l.kind == .remote ? "ssh \(l.name)" : l.name + (l.context.map { " · \($0)" } ?? "")
    }

    static func priority(_ i: Int) -> Double { i == 0 ? 2 : 1 - Double(i) / 100 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(layers.enumerated()), id: \.offset) { i, l in
                if i > 0 { Text(" › ").foregroundStyle(Theme.secondary).fixedSize() }
                Button { click(i) } label: {
                    Text(Self.label(l))
                        .fontWeight(i == 0 || i == focused ? .semibold : .medium)
                        .foregroundStyle(i == 0 ? Theme.primary : Theme.secondary)
                }
                .buttonStyle(.plain).layoutPriority(Self.priority(i))
            }
            Spacer(minLength: 0)
        }
        .font(Theme.small)
        .lineLimit(1)
    }
}

/// A short line at the bottom of the panel, such as "Copied": a saffron bar and muted text on the panel's own tint.
struct Toast: View {
    let text: String
    @Environment(\.colorScheme) var scheme
    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2.5, height: 13)
            Text(text).font(Theme.small).foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.pad).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Theme.tint(scheme == .dark).opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
        .allowsHitTesting(false)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct Footer: View {
    @ObservedObject var model: PanelModel
    let grant: () -> Void
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.needsAccessibility {
                Button(action: grant) { Text("Allow Accessibility to show menu keys").underline() }
                    .buttonStyle(.plain).foregroundStyle(.primary)
            }
            if let n = model.configNote { Text(n).lineLimit(2) }
            // one line for each file that did not load; a click opens the file
            ForEach(Array(model.errorLines.enumerated()), id: \.offset) { _, l in
                Button {
                    switch l.action { case .open(let f): open(f); case .showAll: model.showAllErrors = true }
                } label: { Text(l.text).lineLimit(2).multilineTextAlignment(.leading) }
                .buttonStyle(.plain)
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
    /// True under `ImageRenderer` (the render test): the list is a clipped stack, because `ImageRenderer` does not draw
    /// scroll content, and AppKit views give way to stand-ins.
    @Entry var imageRendering = false
}

struct PanelScroll<Content: View>: View {
    @Binding var position: ScrollPosition
    let offset: (CGFloat) -> Void
    @ViewBuilder var content: Content
    @Environment(\.imageRendering) var flat

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
