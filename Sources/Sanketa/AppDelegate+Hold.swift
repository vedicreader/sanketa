import AppKit
import SanketaCore
import SanketaSystem
import SanketaUI

/// Hold a modifier combo and the panel shows its keys: AeroSpace at the left, the front app at the right.
/// Sanketa sees only which modifier keys are down, and how long since the last other input.
extension AppDelegate {
    static let holdTitles: [(HoldSetting, String)] = [(.all, "All Combos"), (.caps, "Caps Only"), (.off, "Off")]

    static func mods(_ f: NSEvent.ModifierFlags) -> Set<Modifier> {
        var m = Set<Modifier>()
        if f.contains(.control) { m.insert(.ctrl) }
        if f.contains(.option) { m.insert(.opt) }
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.command) { m.insert(.cmd) }
        return m
    }

    func startHold() {
        let d = HoldDetector(delay: config.holdDelay, setting: config.hold, sinceInput: {
            [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
                .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        }, schedule: { delay, block in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(block) } })
        d.onShow = { [weak self] in
            guard let self else { return }
            let t0 = ProcessInfo.processInfo.systemUptime
            showCombo($0)
            let now = ProcessInfo.processInfo.systemUptime
            AeroBarController.log.debug("hold show: \(String(format: "%.3f", t0 - self.lastFlags), privacy: .public) s after the last modifier change, the show took \(String(format: "%.3f", now - t0), privacy: .public) s")
        }
        d.onHide = { [weak self] in   // a mode view stays until the main link, and comes back after a hold
            guard let self else { return }
            if aeroMode == "main" { hideCombo() } else { showCombo([]) }
        }
        panel.onDismiss = { [weak self] in self?.resetAeroMode() }
        hold = d
        let feed: (NSEvent) -> Void = { e in
            let mods = Self.mods(e.modifierFlags), t = e.timestamp, now = ProcessInfo.processInfo.systemUptime
            AeroBarController.log.debug("flags \(mods.map(\.rawValue).sorted().joined(), privacy: .public): delivered \(String(format: "%.3f", now - t), privacy: .public) s after the event")
            MainActor.assumeIsolated { self.lastFlags = now; d.flags(mods, at: t) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: feed)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { feed($0); return $0 }
        readAeroSpace()
        // every place the file can be, so a file that is made later is found
        let reload: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.readAeroSpace() } }
        watchers += AeroSpaceConfig.urls(env: ProcessInfo.processInfo.environment, home: homeDir).map { FileWatcher(url: $0, delay: 0.3, onChange: reload) }
    }

    /// Reads the AeroSpace config again; `aero` is nil when there is no file, and a file that cannot be read shows as an error.
    func readAeroSpace() {
        aeroURL = AeroSpaceConfig.url(env: ProcessInfo.processInfo.environment, home: homeDir) { FileManager.default.fileExists(atPath: $0) }
        aero = nil; model.aeroError = nil
        resetAeroMode()
        guard let u = aeroURL else { return }
        do { aero = AeroSpaceConfig.parse(try String(contentsOf: u, encoding: .utf8)) }
        catch { model.aeroError = PackLoadError(file: u.path, message: "Could not read this file. \(error.localizedDescription)") }
        refreshPinnedCombo()
    }

    /// The AeroSpace keys show in the bar under the menu bar, and the app's keys in the panel. An AeroSpace mode shows
    /// only in the bar. A pinned view stays: a hold does not change it. `force`: an explicit command works also when the
    /// panel has the focus. `bar`: false when the view is pinned at once, so the bar does not flash.
    func showCombo(_ mods: Set<Modifier>, force: Bool = false, bar showsBar: Bool = true) {
        guard !panel.searching, force || !panel.panel.isKeyWindow, !model.comboPinned else {
            return AeroBarController.log.debug("bar skip: searching \(self.panel.searching, privacy: .public), panel key \(self.panel.panel.isKeyWindow, privacy: .public), pinned \(self.model.comboPinned, privacy: .public)")
        }
        let v = comboView(mods)
        if showsBar, v.aero.isEmpty { AeroBarController.log.debug("bar skip: AeroSpace config \(self.aero == nil ? "not read" : "has no keys for this combo", privacy: .public), mode \(self.aeroMode, privacy: .public)") }
        bar.show(showsBar ? AeroBar(view: v) : nil)
        if mods.isEmpty, aeroMode != "main" { return hidePanelCombo() }
        if !panel.isVisible { model.shownForCombo = true; panel.show() }
        setCombo(mods, view: v)
    }

    func comboView(_ mods: Set<Modifier>, appName: String? = nil) -> ComboView {
        ComboView.build(mods: mods, mode: aeroMode, aero: aero, appName: appName ?? monitor.context.appName, apps: comboApps, hyperLabel: config.hyperLabel)
    }

    var comboApps: [AppKeys] { model.sections.map { AppKeys(layer: $0.pack.name, pack: $0.pack.id, entries: $0.groups.flatMap(\.keys)) } }

    /// Builds the view of `mods` from the sections now, with what a key change needs.
    func setCombo(_ mods: Set<Modifier>, appName: String? = nil, view: ComboView? = nil) {
        model.editSources = editSources(comboApps)
        model.showCombo(view ?? comboView(mods, appName: appName), hyperLabel: config.hyperLabel, hasAero: aero != nil)
    }

    func hideCombo() {
        bar.hide()
        hidePanelCombo()
    }

    func hidePanelCombo() {
        if model.hideCombo(), !panel.searching, !panel.panel.isKeyWindow { panel.panel.orderOut(nil) }
    }

    func buildHoldMenu() -> NSMenuItem {
        let sub = NSMenu()
        for (s, title) in Self.holdTitles {
            let i = sub.addItem(withTitle: title, action: #selector(pickHold(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.rawValue
            i.state = s == config.hold ? .on : .off
        }
        let item = NSMenuItem(title: "Show Keys When Held", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    /// Applies live and writes just `hold` back to config.toml.
    @objc func pickHold(_ sender: NSMenuItem) {
        guard let s = (sender.representedObject as? String).flatMap(HoldSetting.init) else { return }
        config.hold = s
        hold?.setting = s
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        markOwnWrite()
        do { try Config.save("hold", "\"\(s.rawValue)\"", to: configURL) }
        catch { configNotSaved(error) }
    }
}
