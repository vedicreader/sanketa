import SwiftUI
import SanketaCore

/// The change of one key in the pinned combo view: which key, then up to three free chords or a pressed chord, then the
/// confirm step. Muted text and plain keys, no boxes.
struct ComboEditSheet: View {
    @ObservedObject var model: PanelModel
    let record: () -> Void
    let apply: () -> Void
    let cancel: () -> Void

    var hyper: String { model.comboHyperLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = model.editing { edit(e) } else { choices }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var choices: some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Text("Change which key?").font(Theme.header).foregroundStyle(Theme.secondary)
            // the first choice is the default: it shows in full weight
            ForEach(Array(model.editChoices.enumerated()), id: \.offset) { i, c in
                Button { model.choose(c) } label: {
                    Text(c.title).font(i == 0 ? Theme.text : Theme.small).foregroundStyle(i == 0 ? Theme.primary : Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, Theme.rowPad)
            }
            link("Cancel", action: cancel).padding(.top, 4)
        }
    }

    func edit(_ e: KeyEdit) -> some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            Text("Change \(e.action)").font(Theme.header).foregroundStyle(Theme.secondary)
            HStack(spacing: 6) {
                KeyLabel(text: e.chord.display(hyperLabel: hyper)).frame(width: Theme.keyColumn, alignment: .leading)
                Text("the key now").font(Theme.small).foregroundStyle(Theme.secondary)
            }
            if let text = model.confirmText {
                Text(text).font(Theme.small).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                if let u = e.inUse {
                    Text(u + (e.blocked ? " Pick a different chord." : "")).font(Theme.small).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 16) {
                    // a chord in use in the same file is never written
                    link("Change", primary: !e.blocked, action: apply).disabled(e.blocked)
                    link("Cancel", action: cancel)
                }
                .padding(.top, 4)
            } else {
                ForEach(Array(e.suggestions.enumerated()), id: \.offset) { _, s in
                    Button { model.pick(s.chord) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            KeyLabel(text: s.chord.display(hyperLabel: hyper)).frame(width: Theme.keyColumn, alignment: .leading)
                            Text(s.reason).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.vertical, Theme.rowPad)
                }
                if e.suggestions.isEmpty { Text("Sanketa found no free chord with these keys.").font(Theme.small).foregroundStyle(Theme.secondary) }
                Button(action: record) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // a thin saffron bar marks the field while it reads the key press
                        RoundedRectangle(cornerRadius: 1).fill(e.recording ? Theme.accent : Theme.hairline).frame(width: 2.5, height: 13)
                        Text(e.recording ? "Press a new chord now. ⎋ stops." : "Press a new chord").font(Theme.small)
                            .foregroundStyle(e.recording ? Theme.primary : Theme.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 4)
                if let w = e.warning { Text(w).font(Theme.small).foregroundStyle(Theme.primary).fixedSize(horizontal: false, vertical: true) }
                if let n = e.note { Text(n).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
                link("Cancel", action: cancel).padding(.top, 4)
            }
        }
    }

    func link(_ title: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).underline() }
            .buttonStyle(.plain).font(primary ? Theme.text : Theme.small).foregroundStyle(primary ? Theme.primary : Theme.secondary)
    }
}
