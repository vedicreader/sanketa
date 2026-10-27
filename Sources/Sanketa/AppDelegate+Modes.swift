import AppKit
import SanketaCore

/// AeroSpace has no hook for a mode change, so a binding that starts a mode also opens `sanketa://aerospace/mode/<name>`.
extension AppDelegate {
    func application(_ app: NSApplication, open urls: [URL]) {
        for name in urls.compactMap(AeroSpaceConfig.modeName) { setAeroMode(name) }
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
        guard let url = aeroURL, let before = try? String(contentsOf: url, encoding: .utf8) else { return }
        let after = AeroSpaceWriter.addModeHook(before)
        if after == before { return savedToast(on) }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Show AeroSpace mode keys?"
        a.informativeText = "Each AeroSpace key that starts a mode will also open a Sanketa link. Then Sanketa can show the keys of that mode. Sanketa keeps a backup of the file: \(url.lastPathComponent).sanketa-bak."
        a.addButton(withTitle: "Change")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        do {
            let ok = try KeyChangeStore(runner: ProcessRunner()).apply(KeyChange(file: url, before: before, after: after, reload: AeroSpaceWriter.reloadCommand()))
            savedToast(ok ? on : "Sanketa changed the file, but aerospace reload-config failed.")
        } catch { savedToast(error.localizedDescription) }
    }
}
