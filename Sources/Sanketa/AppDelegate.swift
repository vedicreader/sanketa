import AppKit
import Combine
import SanketaCore
import SanketaSystem
import SanketaUI

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sanketa")

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = loadConfig()
    var library = loadLibrary()
    lazy var monitor = ContextMonitor(config: config, library: library)
    let model = PanelModel(tips: TipStore(url: supportDir.appendingPathComponent("tips.json")))
    let search = SearchModel()
    lazy var panel = PanelController(model: model, search: search, hotkeyLabel: Theme.display(hotkey: config.hotkey))
    let hotkeys = HotkeyCenter()
    var status: NSStatusItem?
    var subs = Set<AnyCancellable>()
    var rotation: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        if !AXReader.isTrusted { AXReader.promptForTrust() }
        model.packErrors = library.errors
        search.setSource(library: library)
        monitor.$context.sink { [weak self] c in
            self?.model.update(c)
            self?.search.setSource(context: c)
        }.store(in: &subs)
        let ok = Hotkey.parse(config.hotkey).map { hotkeys.register($0) { [weak self] in self?.hotkeyPressed() } } ?? false
        if !ok { model.hotkeyConflict = config.hotkey }
        panel.grantAccessibility = { [weak self] in self?.grantAccessibility() }
        rotation = Timer.scheduledTimer(withTimeInterval: max(10, config.tipRotateSeconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel.isVisible == true { self?.model.rotate() } }
        }
        rotation?.tolerance = 5
        buildStatusItem()
        monitor.start()
        panel.show()
    }

    func hotkeyPressed() {
        if panel.searching { return panel.endSearch() }
        panel.beginSearch(previousApp: NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 })
    }

    func buildStatusItem() {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        s.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Sanketa")
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) { m.addItem(withTitle: title, action: sel, keyEquivalent: "").target = self }
        add("Show/Hide Panel", #selector(togglePanel))
        add("Search  \(Theme.display(hotkey: config.hotkey))", #selector(startSearch))
        m.addItem(.separator())
        add("Reload Packs", #selector(reloadPacks))
        add("Open Packs Folder", #selector(openPacks))
        add("Open Config", #selector(openConfig))
        add("Grant Accessibility…", #selector(grantAccessibility))
        m.addItem(.separator())
        add("Quit Sanketa", #selector(quit))
        s.menu = m
        status = s
    }

    @objc func togglePanel() { panel.toggle() }
    @objc func startSearch() { hotkeyPressed() }

    @objc func reloadPacks() {
        library = loadLibrary()
        model.packErrors = library.errors
        search.setSource(library: library)
        monitor.reload(library: library)
    }

    @objc func openPacks() {
        let d = configDir.appendingPathComponent("packs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        NSWorkspace.shared.open(d)
    }

    @objc func openConfig() {
        let f = configDir.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let c = Config()
            try? """
            # Sanketa settings; restart Sanketa after editing.
            # hotkey = "\(c.hotkey)"
            # pollInterval = \(c.pollInterval)
            # tipRotateSeconds = \(c.tipRotateSeconds)
            # terminals = [\(c.terminals.map { "\"\($0)\"" }.joined(separator: ", "))]

            """.write(to: f, atomically: true, encoding: .utf8)
        }
        guard let edit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else { return }
        NSWorkspace.shared.open([f], withApplicationAt: edit, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func grantAccessibility() {
        AXReader.promptForTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() { NSApp.terminate(nil) }
}
