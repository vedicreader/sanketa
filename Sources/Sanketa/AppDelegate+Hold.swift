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
        let d = HoldDetector(setting: config.hold, sinceInput: {
            [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
                .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        }, schedule: { delay, block in DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(block) } })
        d.onShow = { [weak self] in self?.showCombo($0) }
        d.onHide = { [weak self] in self?.hideCombo() }
        hold = d
        let feed: (NSEvent) -> Void = { e in
            let mods = Self.mods(e.modifierFlags), t = e.timestamp
            MainActor.assumeIsolated { d.flags(mods, at: t) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: feed)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { feed($0); return $0 }
        readAeroSpace()
        if let u = aeroURL { watchers.append(FileWatcher(url: u, delay: 0.3) { [weak self] in MainActor.assumeIsolated { self?.readAeroSpace() } }) }
    }

    /// Reads the AeroSpace config again; nil when there is no file.
    func readAeroSpace() {
        aeroURL = aeroURL ?? AeroSpaceConfig.url(env: ProcessInfo.processInfo.environment, home: homeDir) { FileManager.default.fileExists(atPath: $0) }
        aero = aeroURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(AeroSpaceConfig.parse)
    }

    func showCombo(_ mods: Set<Modifier>) {
        guard !panel.searching, !panel.panel.isKeyWindow else { return }
        let apps = model.sections.map { AppKeys(layer: $0.pack.name, entries: $0.groups.flatMap(\.keys)) }
        let v = ComboView.build(mods: mods, mode: aeroMode, aero: aero, appName: monitor.context.appName, apps: apps, hyperLabel: config.hyperLabel)
        if !panel.isVisible { model.shownForCombo = true; panel.show() }
        model.showCombo(v, hyperLabel: config.hyperLabel, hasAero: aero != nil)
    }

    func hideCombo() {
        model.hideCombo()
        if model.shownForCombo { model.shownForCombo = false; panel.panel.orderOut(nil) }
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
        do { try Config.save("hold", "\"\(s.rawValue)\"", to: configURL) }
        catch { configNotSaved(error) }
    }
}
