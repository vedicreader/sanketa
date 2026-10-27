import SwiftUI
import SanketaCore

/// The keys of a held combo: AeroSpace at the left (when it has a config), the front app at the right, then the free keys.
struct ComboPanel: View {
    let view: ComboView
    let hyperLabel: String
    /// false when there is no AeroSpace config file: the left column then does not show
    var showsAero = true
    /// a row (and true for the AeroSpace column) that can change; a click on it starts the change
    var canEdit: (ComboRow, Bool) -> Bool = { _, _ in false }
    var click: (ComboRow, Bool) -> Void = { _, _ in }

    var combo: String { ComboView.modsLabel(view.mods, hyperLabel) }

    static func emptyAppLine(appName: String, combo: String) -> String { "No \(combo) keys" }
    static func freeLine(_ keys: [String], combo: String) -> String { "Free \(combo) keys: " + keys.joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 24) {
                if showsAero {
                    column("AeroSpace · \(combo)", rows: view.aero, aero: true, notes: view.also, empty: Self.emptyAppLine(appName: "AeroSpace", combo: combo))
                }
                column("\(view.appName) · \(combo)", rows: view.app, aero: false, empty: Self.emptyAppLine(appName: view.appName, combo: combo))
            }
            if !view.free.isEmpty {
                Text(Self.freeLine(view.free, combo: combo)).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 8)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }

    func column(_ title: String, rows: [ComboRow], aero: Bool, notes: [String] = [], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.comboRowGap) {
            Text(title).font(Theme.header).foregroundStyle(Theme.secondary)
            if rows.isEmpty, let empty { Text(empty).font(Theme.small).foregroundStyle(Theme.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if let l = r.layer, i == 0 || rows[i - 1].layer != l {
                    Text(l).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, i == 0 ? 0 : 8)
                }
                if canEdit(r, aero) {
                    Button { click(r, aero) } label: { row(r).contentShape(Rectangle()) }.buttonStyle(.plain)
                } else { row(r) }
            }
            ForEach(notes, id: \.self) { Text($0).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func row(_ r: ComboRow) -> some View {
        let color: Color = r.clash || r.muted ? Theme.secondary : .primary
        let action = Text(r.action).strikethrough(r.clash) + Text(r.clash ? " · AeroSpace" : "")
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            KeyLabel(text: r.keys).strikethrough(r.clash).fixedSize().frame(minWidth: Theme.comboKey, alignment: .leading)
            action.font(Theme.small).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(color)
        .padding(.vertical, Theme.rowPad)
    }
}
