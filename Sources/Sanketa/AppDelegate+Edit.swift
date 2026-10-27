import AppKit
import SanketaCore
import SanketaUI

/// Change a key from the pinned combo view: Sanketa writes Leela's keys.json or the AeroSpace config, with a backup and Undo.
extension AppDelegate {
    func editSources(_ apps: [AppKeys]) -> EditSources {
        EditSources(aero: aero, apps: apps, aeroFile: aero == nil ? nil : aeroURL, leelaFile: LeelaKeymap.defaultURL()) { [weak self] in
            guard let self else { return [] }
            return Set(library.packs.values.flatMap(\.keys).flatMap { $0.chords(hyperLabel: self.config.hyperLabel) })
        }
    }

    /// The pinned view reads the files again, so it shows a changed key.
    func refreshPinnedCombo(appName: String? = nil) {
        guard model.comboPinned, let c = model.combo else { return }
        setCombo(c.mods, appName: appName)
    }

    func buildYourKeysItem() -> NSMenuItem {
        let i = NSMenuItem(title: "Your Keys…", action: #selector(showYourKeys), keyEquivalent: "")
        i.target = self
        return i
    }

    /// The pinned Caps (Hyper) view for the app that was in front; the panel does not take the focus.
    @objc func showYourKeys() {
        if panel.searching { panel.endSearch() }
        model.cancelEdit()
        model.comboPinned = false
        showCombo(Set(Modifier.allCases))
        model.pinCombo()
    }

    /// Writes the change that the user confirmed, then offers Undo in the toast.
    func applyEdit(_ e: KeyEdit) {
        guard let new = e.new, let url = e.file else { return }
        let before: String
        do { before = try String(contentsOf: url, encoding: .utf8) }
        catch { return savedToast("Sanketa cannot read \(url.lastPathComponent). \(error.localizedDescription)") }
        do {
            let after: String, reload: [String]?, isAero: Bool
            switch e.source {
            case .aerospace(let mode):
                after = try AeroSpaceWriter.change(before, mode: mode, from: e.chord, to: new)
                reload = AeroSpaceWriter.reloadCommand(); isAero = true
            case .leela(let action, let live):
                after = try LeelaKeysWriter.change(before, action: action, live: live, from: e.chord, to: new)
                reload = nil; isAero = false
            }
            let change = KeyChange(file: url, before: before, after: after, reload: reload)
            let ok = try KeyChangeStore(runner: ProcessRunner()).apply(change)
            changedToast(!ok ? PanelModel.reloadFailed : isAero && reload == nil ? "Changed. Run aerospace reload-config to use the new key." : "Changed.", change)
            if isAero { readAeroSpace() } else { reloadPacks() }
        } catch { savedToast(error.localizedDescription) }
    }

    func changedToast(_ text: String, _ change: KeyChange) {
        panel.show()
        model.showSaveToast(text, action: ToastAction(title: "Undo") { [weak self] in self?.undoChange(change) })
    }

    /// Undo writes the file as it was before the change, if nobody changed it since.
    func undoChange(_ c: KeyChange) {
        do {
            let ok = try KeyChangeStore(runner: ProcessRunner()).undo(c)
            savedToast(ok ? "Sanketa undid the change." : PanelModel.reloadFailed)
            if c.file == aeroURL { readAeroSpace() } else { reloadPacks() }
        } catch { savedToast(error.localizedDescription) }
    }
}
