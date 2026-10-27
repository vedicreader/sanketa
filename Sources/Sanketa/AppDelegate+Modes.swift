import AppKit
import SanketaCore

/// AeroSpace has no hook for a mode change, so a binding that starts a mode also opens `sanketa://aerospace/mode/<name>`.
extension AppDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        for name in urls.compactMap(AeroSpaceConfig.modeName) {
            if let m = AeroSpaceConfig.nextMode(name, known: aero?.modes.keys.map { $0 } ?? []) { setAeroMode(m) }
        }
    }

    /// Back to `main`, with no mode view: the panel was hidden by hand, or the config was read again.
    func resetAeroMode() {
        guard aeroMode != "main" else { return }
        aeroMode = "main"
        hideCombo()
    }

    /// A mode other than `main` shows its keys, without the focus, until `main` comes.
    func setAeroMode(_ name: String) {
        aeroMode = name
        if name == "main" { hideCombo() } else { showCombo([]) }
    }

    func buildAeroModeItem() -> NSMenuItem {
        let i = NSMenuItem(title: "Show AeroSpace Mode Keys…", action: #selector(showAeroModeKeys), keyEquivalent: "")
        i.target = self
        return i
    }

    /// The item shows only when an AeroSpace config file exists.
    func refreshAeroModeItem(_ menu: NSMenu) {
        menu.items.first { $0.action == #selector(showAeroModeKeys) }?.isHidden = aeroURL == nil
    }

    @objc func showAeroModeKeys() {
        let on = "AeroSpace mode keys are on."
        guard let url = aeroURL else { return }
        let before: String
        do { before = try String(contentsOf: url, encoding: .utf8) }
        catch { return savedToast("Sanketa cannot read \(url.lastPathComponent). \(error.localizedDescription)") }
        let after = AeroSpaceWriter.addModeHook(before)
        if after == before { return savedToast(on) }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Show AeroSpace mode keys?"
        a.informativeText = "Each AeroSpace key that starts a mode will also open a Sanketa link. Then Sanketa can show the keys of that mode. Sanketa keeps a copy of the file: \(url.lastPathComponent).sanketa-bak. Then Sanketa runs aerospace reload-config."
        a.addButton(withTitle: "Change")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let reload = AeroSpaceWriter.reloadCommand()
            let ok = try KeyChangeStore(runner: ProcessRunner()).apply(KeyChange(file: url, before: before, after: after, reload: reload))
            savedToast(!ok ? "Sanketa changed the file, but aerospace reload-config failed."
                       : reload == nil ? "Sanketa changed the file. Run aerospace reload-config to turn the mode keys on." : on)
        } catch { savedToast(error.localizedDescription) }
    }
}
