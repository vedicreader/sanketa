import SwiftUI
import SanketaCore

/// The keys of a combo. While held: only the front app's column, as the AeroSpace keys show in the bar. Pinned: wide,
/// AeroSpace at the left (when it has a config), the front app at the right, then the free keys. Sanketa's own keys
/// end the app column.
struct ComboPanel: View {
    let view: ComboView
    let hyperLabel: String
    /// false when there is no AeroSpace config file: the left column then does not show
    var showsAero = true
    /// the user clicked the view: it stays, it is wide, and its keys can change
    var pinned = false
    /// Sanketa's own rows (Search), and true when macOS or another app has Search's chord
    var own: [ComboRow] = []
    var ownTaken = false
    /// a row (and true for the AeroSpace column) that can change; a click on it starts the change
    var canEdit: (ComboRow, Bool) -> Bool = { _, _ in false }
    var click: (ComboRow, Bool) -> Void = { _, _ in }

    var combo: String { ComboView.modsLabel(view.mods, hyperLabel) }

    static func emptyAppLine(appName: String, combo: String) -> String { "No \(combo) keys" }
    static func freeLine(_ keys: [String], combo: String) -> String { "Free \(combo) keys: " + keys.joined(separator: " ") }
    static func footer(pinned: Bool) -> String { pinned ? "Esc or a click outside closes this." : "Click to keep this open" }
    static func showsAeroColumn(pinned: Bool, hasAero: Bool) -> Bool { pinned && hasAero }
    static func showsFree(pinned: Bool) -> Bool { pinned }
    static let ownHeader = "Sanketa"
    static let taken = "✕ taken · "

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 24) {
                if Self.showsAeroColumn(pinned: pinned, hasAero: showsAero) {
                    column("AeroSpace · \(combo)", rows: view.aero, aero: true, notes: view.also, empty: Self.emptyAppLine(appName: "AeroSpace", combo: combo))
                }
                column("\(view.appName) · \(combo)", rows: view.app, aero: false, empty: Self.emptyAppLine(appName: view.appName, combo: combo), own: own)
            }
            if Self.showsFree(pinned: pinned), !view.free.isEmpty {
                Text(Self.freeLine(view.free, combo: combo)).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 8)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }

    /// A grid, so each column's keys are as wide as its widest key (`← ↑ ↓ →`, `1 — 9`); the actions start after them.
    func column(_ title: String, rows: [ComboRow], aero: Bool, notes: [String] = [], empty: String? = nil, own: [ComboRow] = []) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.comboKeyGap, verticalSpacing: Theme.comboRowGap) {
            Text(title).font(Theme.header).foregroundStyle(Theme.secondary)
            if rows.isEmpty, let empty { Text(empty).font(Theme.small).foregroundStyle(Theme.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if let l = r.layer, i == 0 || rows[i - 1].layer != l {
                    Text(l).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, i == 0 ? 0 : 8)
                }
                row(r, aero: aero)
            }
            ForEach(notes, id: \.self) { Text($0).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 2) }
            if !own.isEmpty {
                Text(Self.ownHeader).font(Theme.header).foregroundStyle(Theme.secondary).padding(.top, 10)
                ForEach(Array(own.enumerated()), id: \.offset) { _, r in row(r, aero: false) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func row(_ r: ComboRow, aero: Bool) -> some View {
        let taken = ownTaken && r.pack == PanelModel.sanketaPack
        let action = Text(r.action).strikethrough(r.clash) + Text(r.clash ? " · AeroSpace" : "")
            + Text(taken ? "  " + Self.taken : "").foregroundStyle(Theme.secondary) + Text(taken ? "Change" : "").underline()
        return GridRow {
            cell(r, aero: aero) { KeyLabel(text: r.keys).strikethrough(r.clash) }
            cell(r, aero: aero) { action.font(Theme.small).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .foregroundStyle(r.clash || r.muted || taken ? Theme.secondary : .primary)
        .padding(.vertical, Theme.rowPad)
    }

    /// A cell of a row that can change is a button; both cells of the row do the same.
    @ViewBuilder func cell(_ r: ComboRow, aero: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        if canEdit(r, aero) {
            Button { click(r, aero) } label: { content().contentShape(Rectangle()) }.buttonStyle(.plain)
        } else { content() }
    }
}
