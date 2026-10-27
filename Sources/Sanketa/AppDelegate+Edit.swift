import AppKit
import SanketaCore
import SanketaUI

/// Change a key from the pinned combo view: Sanketa writes Leela's keys.json or the AeroSpace config, with a backup and Undo.
extension AppDelegate {
    func editSources(_ apps: [AppKeys]) -> EditSources {
        EditSources(aero: aero, apps: apps, aeroFile: aero == nil ? nil : aeroURL, leelaFile: LeelaKeymap.defaultURL(), known: { [weak self] in
            guard let self else { return [] }
            return Set(library.packs.values.flatMap(\.keys).flatMap { $0.chords(hyperLabel: self.config.hyperLabel) })
        }, sanketaFile: configURL, system: { KeySuggest.systemChords.union(HotkeyCenter.systemChords()) })
    }

    /// The pinned view reads the files again, so it shows a changed key.
    func refreshPinnedCombo(appName: String? = nil) {
        guard model.pinnedRefreshable, let c = model.combo else { return }
        setCombo(c.mods, appName: appName)
    }

    func buildYourKeysItem() -> NSMenuItem {
        let i = NSMenuItem(title: "Change Keys…", action: #selector(showYourKeys), keyEquivalent: "")
        i.target = self
        return i
    }

    /// The pinned Caps (Hyper) view for the app that was in front; the panel does not take the focus.
    @objc func showYourKeys() {
        if panel.searching { panel.endSearch() }
        model.cancelEdit()
        model.comboPinned = false
        showCombo(Set(Modifier.allCases), force: true, bar: false)
        model.pinCombo()
    }

    /// Writes the change that the user confirmed, then offers Undo in the toast.
    func applyEdit(_ e: KeyEdit) {
        guard let new = e.new, let url = e.file else { return }
        let before: String
        // Sanketa's own config.toml can be missing: an empty file has the defaults
        if case .sanketa = e.source, !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data().write(to: url)
        }
        do { before = try String(contentsOf: url, encoding: .utf8) }
        catch { return savedToast("Sanketa cannot read \(url.lastPathComponent). \(error.localizedDescription)") }
        do {
            let after: String, reload: [String]?, isAero: Bool
            switch e.source {
            case .sanketa:
                let change = KeyChange(file: url, before: before, after: try SanketaConfigWriter.change(before, to: new), reload: nil)
                _ = try KeyChangeStore(runner: ProcessRunner()).apply(change)
                reloadConfig()   // registers the new hotkey now
                return changedToast(hotkeyText(changed: true), change)
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
            if c.file == configURL {
                reloadConfig()
                return savedToast(hotkeyText(changed: false))
            }
            let needsReload = c.file == aeroURL && c.reload == nil
            savedToast(!ok ? PanelModel.reloadFailed : needsReload ? "Sanketa undid the change. Run aerospace reload-config to use the old key." : "Sanketa undid the change.")
            if c.file == aeroURL { readAeroSpace() } else { reloadPacks() }
        } catch { savedToast(error.localizedDescription) }
    }

    /// The toast after a change of the search hotkey, or its Undo: it says so when Sanketa cannot register the chord.
    func hotkeyText(changed: Bool) -> String {
        let done = changed ? "Changed." : "Sanketa undid the change."
        guard let h = model.hotkeyConflict else { return done }
        return done + " But Sanketa cannot use \(Theme.display(hotkey: h)). macOS or another app uses it."
    }
}
