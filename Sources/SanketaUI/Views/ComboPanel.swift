import SwiftUI
import SanketaCore

/// The keys of a held combo: AeroSpace at the left (when it has a config), the front app at the right, then the free keys.
struct ComboPanel: View {
    let view: ComboView
    let hyperLabel: String
    /// false when there is no AeroSpace config file: the left column then does not show
    var showsAero = true

    var combo: String { ComboView.modsLabel(view.mods, hyperLabel) }

    static func emptyAppLine(appName: String, combo: String) -> String { "No \(combo) keys" }
    static func freeLine(_ keys: [String], combo: String) -> String { "Free \(combo) keys: " + keys.joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 14) {
                if showsAero {
                    column("AeroSpace · \(combo)", rows: view.aero, notes: view.also, empty: Self.emptyAppLine(appName: "AeroSpace", combo: combo))
                }
                column("\(view.appName) · \(combo)", rows: view.app, empty: Self.emptyAppLine(appName: view.appName, combo: combo))
            }
            if !view.free.isEmpty {
                Text(Self.freeLine(view.free, combo: combo)).font(Theme.small).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }

    func column(_ title: String, rows: [ComboRow], notes: [String] = [], empty: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Text(title).font(Theme.header).foregroundStyle(Theme.secondary)
            if rows.isEmpty, let empty { Text(empty).font(Theme.small).foregroundStyle(Theme.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if let l = r.layer, i == 0 || rows[i - 1].layer != l {
                    Text(l).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, i == 0 ? 0 : 2)
                }
                row(r)
            }
            ForEach(notes, id: \.self) { Text($0).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func row(_ r: ComboRow) -> some View {
        let color: Color = r.clash || r.muted ? Theme.secondary : .primary
        let why = Text(" · AeroSpace").font(Theme.small)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                KeyLabel(text: r.keys).strikethrough(r.clash).frame(width: Theme.keyColumn, alignment: .leading)
                HStack(spacing: 0) {
                    Text(r.action).font(Theme.small).strikethrough(r.clash)
                    if r.clash { why }
                }.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 0) {
                KeyLabel(text: r.keys).strikethrough(r.clash)
                HStack(spacing: 0) {
                    Text(r.action).font(Theme.small).strikethrough(r.clash)
                    if r.clash { why }
                }
            }
        }
        .foregroundStyle(color)
        .padding(.vertical, Theme.rowPad)
    }
}
