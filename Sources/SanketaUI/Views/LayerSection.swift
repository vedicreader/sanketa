import AppKit
import SwiftUI
import SanketaCore

struct LayerSection: View {
    let data: LayerSectionData
    let collapsed: Bool
    var selected = false
    /// false when the panel has only this section: the breadcrumb above already names it
    var showsName = true
    var folded: (RowGroup) -> Bool = { _ in false }
    var toggleGroup: (RowGroup) -> Void = { _ in }
    /// the row id (`PanelModel.rowID`) that shows all its text
    var expandedRow: String?
    var toggleRow: (String) -> Void = { _ in }
    var copy: (String) -> Void = { _ in }
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    if showsName {
                        Text(data.pack.name + (data.layer.host.map { " @ \($0)" } ?? "") + (data.layer.context.map { " · \($0)" } ?? ""))
                            .font(Theme.header)
                    }
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
                    if !shut { ForEach(Array(g.keys.enumerated()), id: \.offset) { i, k in
                        let id = PanelModel.rowID(data, g, i)
                        KeyRow(key: k, prefix: data.pack.prefix, expanded: expandedRow == id, toggle: { toggleRow(id) }, copy: copy)
                    } }
                }
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        // keyboard focus: a saffron tick beside the header, not a box
        .overlay(alignment: .topLeading) {
            if selected { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2.5, height: 14).offset(x: -1, y: 4) }
        }
    }
}

/// One key: the action on the left and the keys on the right, one or two lines. A click shows all the text, with the
/// full command when the key has one; a second click makes it short again. It never folds the group. On hover, a copy
/// button at the trailing edge copies the command, when there is one, and a tooltip gives the full text.
struct KeyRow: View {
    let key: KeyEntry
    let prefix: String?
    let expanded: Bool
    let toggle: () -> Void
    let copy: (String) -> Void
    @State var hover = false

    var full: String { [key.action, KeyNotation.display(key.keys, prefix: prefix), key.command].compactMap { $0 }.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                // disabled menu items stay listed, dimmed: their state changes with context
                Text(key.action).font(Theme.text).foregroundStyle(key.enabled == false ? Theme.secondary : .primary)
                    .lineLimit(expanded ? nil : 2).fixedSize(horizontal: false, vertical: expanded)
                Spacer(minLength: 10)
                KeyChip(keys: key.keys, prefix: prefix, dimmed: key.enabled == false)
                    .frame(minWidth: Theme.keyColumn, alignment: .trailing).layoutPriority(1)
            }
            if expanded, let c = key.command, c != key.action {
                Text(c).font(Theme.snippet).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, Theme.rowPad)
        // a slot for the copy button inside the row, so the pointer stays in the hover area on its way to the button
        .padding(.trailing, CopyButton.slot)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .overlay(alignment: .topTrailing) {
            if hover, let t = PanelModel.copyText(key) { CopyButton { copy(t) } }
        }
        .onHover { hover = $0 }
        .help(full)
    }
}

/// A small copy icon in the secondary colour, with no box. A click copies and does not take focus.
struct CopyButton: View {
    /// the width that a row keeps free at its trailing edge for the button
    static let slot: CGFloat = 14
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc").font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary)
                .frame(width: 12, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel("Copy")
    }
}

/// The link under the menu keys of a GUI app with no pack. It opens Make a Pack.
struct MakePackLink: View {
    let layer: Layer
    var makePack: (Layer) -> Void = { _ in }

    var body: some View {
        Button { makePack(layer) } label: { Text(NoPackSection.link(layer.name)).underline() }
            .buttonStyle(.plain).font(Theme.small).foregroundStyle(.primary)
            .padding(.vertical, 4).padding(.horizontal, 6)
    }
}

/// A program or shell with no pack: its name as a header, one line that says so, and a link that makes a pack.
struct NoPackSection: View {
    let layer: Layer
    var makePack: (Layer) -> Void = { _ in }

    static func message(_ name: String) -> String { "Sanketa has no keys for \(name)." }
    static func link(_ name: String) -> String { "Make a pack for \(name)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Text(layer.name + (layer.host.map { " @ \($0)" } ?? "")).font(Theme.header).foregroundStyle(Theme.secondary)
            Text(Self.message(layer.name)).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Button { makePack(layer) } label: { Text(Self.link(layer.name)).underline() }
                .buttonStyle(.plain).font(Theme.small).foregroundStyle(.primary)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }
}
