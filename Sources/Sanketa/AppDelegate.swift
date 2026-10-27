import AppKit
import UniformTypeIdentifiers
import Combine
import SanketaCore
import SanketaSystem
import SanketaUI
import SanketaAI
import SanketaMLX
import SanketaVault

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sanketa")

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config: Config
    /// why config.toml did not load, for the footer and Copy Debug Info
    var configError: String?
    /// a note from the config load, such as the memory fallback; not an error
    var configNote: String?
    lazy var library = loadLibrary(config: config)
    lazy var monitor = ContextMonitor(config: config, library: library)
    lazy var coach = CoachMonitor(config: config.coach)
    let tips = TipStore(url: supportDir.appendingPathComponent("tips.json"))
    lazy var model = PanelModel(tips: tips)
    let search = SearchModel()
    /// the model tiers from `[llm]`; rebuilt when `[llm]` changes
    lazy var llm = makeLLM(config.llm)
    /// the model loads at most once a minute when the panel opens
    let prewarmGate = Throttle(60)
    /// the vault search and writer from `[vault]`
    var vault: (search: VaultSearching?, writer: VaultWriting?)?
    /// the vault server client of `vault`, when there is one
    var hybrid: VaultHybrid? { vault?.writer as? VaultHybrid }
    /// the vault tools that this Mac has, for the status menu; detected again when the menu opens
    var tools = VaultTools(vaultFile: false, server: false, abhyasa: false)
    /// true while "Set Up the Vault…" runs
    var settingUpVault = false
    /// tells the status menu if the abhyasa server answers; it asks at most once in 10 seconds
    var menuProbe: AbhyasaProbe?
    /// model suggestions run at most once per 10 minutes, and only after the history changed
    let suggestGate = Throttle(600)
    var suggestGeneration = -1
    var suggestions: [SearchItem] = []
    lazy var menus = ModelMenus(llm: { [unowned self] in llm }, config: { [unowned self] in config.llm }) { [unowned self] c in
        config.llm = c
        rebuildLLM()
    }
    lazy var panel = PanelController(model: model, search: search, hotkeyLabel: Theme.display(hotkey: config.hotkey))
    let hotkeys = HotkeyCenter()
    var status: NSStatusItem?
    var subs = Set<AnyCancellable>()
    var rotation: Timer?
    var searchItem: NSMenuItem?
    /// Leela's keys.json, the user packs folder and config.toml: a save applies without a restart
    var watchers: [FileWatcher] = []
    /// the open Make a Pack window, and the status-menu item that opens it
    var packMaker: PackMakerWindow?
    var makePackItem: NSMenuItem?

    override init() {
        (config, configError, configNote) = readConfig()
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // no menu bar shows; the Edit menu gives the search field ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z and ⇧⌘Z
        NSApp.mainMenu = EditMenu.make()
        search.resume = { [weak self] in self?.resumeSession($0) ?? false }
        // a save can make the vault file: look for it again
        search.toast = { [weak self] in self?.savedToast($0); self?.detectTools() }
        search.writeMarkdown = { try VaultMarkdown.write(title: $0, text: $1, shelf: $2, doc: $3) }
        if !AXReader.isTrusted { AXReader.promptForTrust() }
        model.packErrors = library.errors
        search.setSource(library: library)
        monitor.$context.sink { [weak self] c in
            self?.model.update(c)
            self?.search.setSource(context: c)
        }.store(in: &subs)
        coach.$items.sink { [weak self] items in
            guard let self else { return }
            model.coachItems = items + suggestions
            search.setSource(extra: items)
            // `generation` is set just before `items` changes; suggest after this run-loop turn, with both set
            DispatchQueue.main.async { self.suggestIfDue() }
        }.store(in: &subs)
        search.setSmart(SmartSearch(router: llm.router, timeout: config.llm.timeoutSeconds))
        applyVault()
        panel.prewarm = { [weak self] in self?.prewarm() }
        registerHotkey()
        panel.grantAccessibility = { [weak self] in self?.grantAccessibility() }
        panel.openFile = { [weak self] in self?.openForEditing(URL(fileURLWithPath: $0)) }
        panel.makePack = { [weak self] layer in
            guard let self else { return }
            if layer.kind == .app { if case .app(let app) = makePackTarget() { openPackMaker(app) } } else { makeStarter(layer) }
        }
        panel.setTranslucency(config.translucency)
        scheduleRotation()
        buildStatusItem()
        model.configError = configError.map { PackLoadError(file: configURL.path, message: $0) }
        model.configNote = configNote
        try? FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
        let reload: () -> Void = { [weak self] in MainActor.assumeIsolated { self?.reloadPacks() } }
        watchers = [FileWatcher(url: LeelaKeymap.defaultURL(), onChange: reload),
                    FileWatcher(url: packsDir, children: "toml", delay: 0.3, onChange: reload),
                    FileWatcher(url: configURL, delay: 0.3) { [weak self] in MainActor.assumeIsolated { self?.reloadConfig() } }]
        monitor.start()
        coach.start()
        panel.show()
    }

    func registerHotkey() {
        hotkeys.unregisterAll()
        let ok = Hotkey.parse(config.hotkey).map { hotkeys.register($0) { [weak self] in self?.hotkeyPressed() } } ?? false
        model.hotkeyConflict = ok ? nil : config.hotkey
        panel.field.placeholderString = "Search  \(Theme.display(hotkey: config.hotkey))"
        searchItem?.title = "Search  \(Theme.display(hotkey: config.hotkey))"
    }

    func scheduleRotation() {
        rotation?.invalidate()
        rotation = Timer.scheduledTimer(withTimeInterval: max(10, config.tipRotateSeconds), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel.isVisible == true { self?.model.rotate() } }
        }
        rotation?.tolerance = 5
    }

    /// config.toml was saved: apply the hotkey, translucency, terminals, poll and tip timing, and the Hyper label.
    func reloadConfig() {
        let old = config
        (config, configError, configNote) = readConfig()
        model.configError = configError.map { PackLoadError(file: configURL.path, message: $0) }
        model.configNote = configNote
        guard config != old else { return }
        if config.hotkey != old.hotkey { registerHotkey() }
        if config.translucency != old.translucency {
            panel.setTranslucency(config.translucency)
            status?.menu?.item(withTitle: "Translucency")?.submenu?.items.forEach {
                $0.state = $0.representedObject as? String == config.translucency.rawValue ? .on : .off
            }
        }
        if config.tipRotateSeconds != old.tipRotateSeconds { scheduleRotation() }
        if config.hyperLabel != old.hyperLabel { library = loadLibrary(config: config); model.packErrors = library.errors; search.setSource(library: library) }
        if config.llm != old.llm { rebuildLLM() }
        if config.vault != old.vault || config.abhyasa != old.abhyasa { applyVault() }
        monitor.reload(config: config, library: library)
        coach.reload(config: config.coach)
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
        add("Show or Hide Panel", #selector(togglePanel))
        add("Search  \(Theme.display(hotkey: config.hotkey))", #selector(startSearch))
        searchItem = m.items.last
        let tr = NSMenu()
        for t in Translucency.allCases {
            let i = tr.addItem(withTitle: t.rawValue.capitalized, action: #selector(pickTranslucency(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.rawValue
            i.state = t == config.translucency ? .on : .off
        }
        m.addItem(withTitle: "Translucency", action: nil, keyEquivalent: "").submenu = tr
        menus.add(to: m)
        m.addItem(.separator())
        for key in VaultToggles.Key.allCases {
            let i = m.addItem(withTitle: "", action: #selector(toggleVault(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key.rawValue
        }
        refreshVaultToggles(m)
        m.addItem(.separator())
        add("Reload Packs", #selector(reloadPacks))
        add("Open Packs Folder", #selector(openPacks))
        add("Make a Pack…", #selector(makePackFromMenu))
        makePackItem = m.items.last
        add("Open Config", #selector(openConfig))
        add("Allow Accessibility…", #selector(grantAccessibility))
        add("Copy Debug Info", #selector(copyDebugInfo))
        m.addItem(.separator())
        add("Quit Sanketa", #selector(quit))
        m.delegate = self
        s.menu = m
        status = s
    }

    @objc func togglePanel() { panel.toggle() }

    // MARK: vault and abhyasa

    /// Is Abhyasa.app installed: LaunchServices has an app for `abhyasa://` links. No process starts.
    nonisolated static func abhyasaInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "abhyasa://")!) != nil
    }

    /// Looks for the vault file, the vault server and abhyasa again. File checks only: the abhyasa server answer is the
    /// last one that the probe has. With `[abhyasa] enabled = false`, the line stays on, so the user can turn it on again.
    func currentTools() -> VaultTools {
        let off = !config.abhyasa.enabled, probe = menuProbe
        return VaultTools.detect(config) { off || probe?.cached != nil }
    }

    /// The tools now. A vault file or a server that came or went: search uses what is there now.
    func detectTools() {
        let old = tools
        tools = currentTools()
        if tools.vaultFile != old.vaultFile || tools.server != old.server { applyVault() }
    }

    /// Titles, check marks and states of the vault lines, from the config and the tools.
    func refreshVaultToggles(_ m: NSMenu) {
        detectTools()
        let lines = VaultToggles.lines(config, tools, settingUp: settingUpVault)
        for key in VaultToggles.Key.allCases {
            guard let i = m.items.first(where: { $0.representedObject as? String == key.rawValue }) else { continue }
            guard let line = lines.first(where: { $0.key == key })?.line else { i.isHidden = true; continue }
            i.isHidden = false
            i.title = line.title
            i.state = line.checked ? .on : .off
            i.isEnabled = line.enabled
        }
    }

    /// The status menu opens: the lines show at once; when the abhyasa server answers later, they change.
    func refreshVaultMenu(_ m: NSMenu) {
        refreshVaultToggles(m)
        guard config.abhyasa.enabled, let probe = menuProbe, !Self.abhyasaInstalled() else { return }
        Task { [weak self, weak m] in
            let before = probe.cached
            let now = await probe.up()
            guard now != before, let self, let m else { return }
            refreshVaultToggles(m)
        }
    }

    /// Writes the toggle's key to config.toml, then applies the config. "Set Up the Vault…" asks first. "Get the Abhyasa
    /// App…" opens the download page.
    @objc func toggleVault(_ sender: NSMenuItem) {
        guard let key = (sender.representedObject as? String).flatMap(VaultToggles.Key.init) else { return }
        if key == .abhyasa, !tools.abhyasa { NSWorkspace.shared.open(VaultToggles.abhyasaDownload); return }   // the download page
        guard let c = VaultToggles.change(key, config) else { return setUpVault() }
        do { try Config.save(c.key, c.value, to: configURL, table: c.table) }
        catch { configNotSaved(error) }
        reloadConfig()
    }

    /// Asks once, then runs `uv tool install vishalakshi` off the main thread. The toast shows the progress and the
    /// result. Then Sanketa looks for the vault server again. Nothing runs before the user clicks Set Up.
    func setUpVault() {
        guard !settingUpVault else { return }
        let uv = VaultSetup.findUV()
        let a = NSAlert()
        a.messageText = VaultSetup.title
        a.informativeText = VaultSetup.message(uv: uv)
        if uv == nil { a.addButton(withTitle: "OK") } else { a.addButton(withTitle: "Set Up"); a.addButton(withTitle: "Cancel") }
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn, let uv else { return }
        settingUpVault = true
        savedToast(VaultSetup.started)
        Task.detached {
            let result = VaultSetup.run(uv: uv, runner: ProcessRunner())
            await MainActor.run {
                self.settingUpVault = false
                self.savedToast(result)
                self.applyVault()
                if let m = self.status?.menu { self.refreshVaultToggles(m) }
            }
        }
    }

    /// ⌥Return on a ramabana session: a new window in the tmux session that the user used last, else a new window of
    /// the terminal app. False: Sanketa could not start it.
    func resumeSession(_ id: String) -> Bool {
        let tmuxClients = SysctlProcesses.snapshot().procs.filter { $0.name == "tmux" && $0.tty != nil }.map { (path: $0.path, argv: $0.argv) }
        let ramabana = ["~/.local/bin/ramabana", "/opt/homebrew/bin/ramabana", "/usr/local/bin/ramabana"]
            .map { ($0 as NSString).expandingTildeInPath }.first(where: FileManager.default.isExecutableFile)
        let r = SessionResume(runner: ProcessRunner(),
                              servers: SessionResume.servers(clients: tmuxClients, fallback: ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]),
                              ramabana: ramabana)
        if r.inTmux(id) { return true }
        guard let text = r.script(id), let app = terminalApp() else { return false }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-resume-\(id).command")
        do {
            try text.write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        } catch { return false }
        NSWorkspace.shared.open([f], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// The first terminal of `terminals` that runs, else the first that is installed.
    func terminalApp() -> URL? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let ids = config.terminals.filter(running.contains) + config.terminals
        return ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    // MARK: make a pack

    /// What "Make a Pack" works on: the GUI app in front, or the program in front in a terminal.
    enum MakePackTarget { case app(NSRunningApplication), program(Layer), none }

    /// From the context of the app that was in front before the menu opened; the menu does not change it. Never Sanketa.
    func makePackTarget() -> MakePackTarget {
        let c = monitor.context
        switch PackMaker.target(bundleID: c.bundleID, own: Bundle.main.bundleIdentifier, terminals: config.terminals, layers: c.layers) {
        case .app(let bid): return running(bid).map(MakePackTarget.app) ?? .none
        case .program(let l): return .program(l)
        case .none: return .none
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === status?.menu, let item = makePackItem else { return }
        refreshVaultMenu(menu)
        switch makePackTarget() {
        case .app(let a): item.title = "Make a Pack for \(appName(a))…"; item.isEnabled = true; item.toolTip = nil
        case .program(let l): item.title = "Make a Pack for \(l.name)…"; item.isEnabled = true; item.toolTip = nil
        case .none: item.title = "Make a Pack…"; item.isEnabled = false; item.toolTip = "No app is in front."
        }
    }

    @objc func makePackFromMenu() {
        switch makePackTarget() {
        case .app(let a): openPackMaker(a)
        case .program(let l): makeStarter(l)
        case .none: break
        }
    }

    /// A first pack for a program in a terminal, opened in the editor. The toast tells the file, or why it failed.
    func makeStarter(_ layer: Layer) {
        do {
            let f = try PackStarter.make(for: layer, in: packsDir)
            savedToast("Saved \(f.lastPathComponent).")
            openForEditing(f)
        } catch {
            FileHandle.standardError.write(Data("cannot make a pack for \(layer.name): \(error.localizedDescription)\n".utf8))
            savedToast("Sanketa cannot write the pack for \(layer.name): \(error.localizedDescription)")
        }
    }

    /// A menu change that config.toml did not keep: the reason goes to the log and the toast.
    func configNotSaved(_ e: Error) {
        FileHandle.standardError.write(Data("cannot save config: \(e.localizedDescription)\n".utf8))
        savedToast("Sanketa cannot save the config: \(e.localizedDescription)")
    }

    /// What a save did, or why it did not: the panel shows, without the focus, with the toast for `saveToastSeconds`.
    func savedToast(_ text: String) {
        guard !text.isEmpty else { return }
        panel.show()
        model.showSaveToast(text)
    }

    func appName(_ a: NSRunningApplication) -> String {
        let info = a.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? a.localizedName ?? a.bundleIdentifier ?? "app"
    }

    /// The Make a Pack window for a GUI app. The prompt gets the name, version and bundle id from the app bundle, and the
    /// menu shortcuts from Accessibility. It never reads the window title.
    func openPackMaker(_ a: NSRunningApplication) {
        guard let bid = a.bundleIdentifier, !bid.isEmpty else {
            return KeyBox.tell("No bundle id", "This app has no bundle id. Sanketa cannot make a pack for it.")
        }
        if let w = packMaker, w.model.app.bundleID == bid { return w.show() }
        // the window for another app closes quietly: the new window takes the focus, so there is nothing to give back
        let old = packMaker
        packMaker = nil
        old?.window.close()
        let version = a.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        // a user pack for the app keeps its file and id, so a save never makes a second pack for the app
        let user = PackMaker.userPackFile(bundleID: bid, in: packsDir)
        let app = PackMaker.App(name: appName(a), bundleID: bid, version: version, packID: user?.pack.id)
        let pid = a.processIdentifier
        Task.detached {
            let menu = AXReader.isTrusted ? AXReader.menuShortcuts(pid: pid) : []
            await MainActor.run { self.showPackMaker(app, menu: menu, userPack: user?.url, previous: a) }
        }
    }

    /// The prompt gets the user pack (keys and tips, no comments) when there is one, else the bundled pack for the app.
    /// A save reloads the packs and shows the panel with a toast that names the file; then the window closes. Each close gives the
    /// focus back to `previous`, the app that was in front, as Esc does in the panel.
    func showPackMaker(_ app: PackMaker.App, menu: [MenuShortcut], userPack: URL?, previous: NSRunningApplication) {
        let bundled = PackMaker.userPackFile(bundleID: app.bundleID, in: bundledPacks())
        let existing = bundled.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) }
        let sender = llm.packMaker(), mlx = llm.router.onDevice as? MLXChooser
        let maker = PackMakerModel(.init(
            app: app, menu: menu, existing: existing, userPack: userPack, config: config.llm, provider: llm.providerName,
            onDeviceReady: mlx?.status() == .available,
            sendOpenAI: sender.map { s in { try await s.send($0) } },
            sendOnDevice: mlx.map { m in { try await m.makePack($0) } },
            packsDir: packsDir, confirmReplace: { PackMakerWindow.confirmReplace($0) },
            saved: { [weak self] _ in self?.reloadPacks() },
            toast: { [weak self] in self?.savedToast($0) }))
        let w = PackMakerWindow(model: maker, provider: llm.providerName)
        w.onClose = { [weak self, weak w] in
            guard let self, packMaker === w else { return }
            packMaker = nil
            panel.handBack(to: previous)
        }
        packMaker = w
        w.show()
    }

    /// Applies live and writes just `translucency` back to config.toml.
    @objc func pickTranslucency(_ sender: NSMenuItem) {
        guard let t = (sender.representedObject as? String).flatMap(Translucency.init) else { return }
        config.translucency = t
        panel.setTranslucency(t)
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        do { try Config.save("translucency", "\"\(t.rawValue)\"", to: configURL) }
        catch { configNotSaved(error) }
    }
    @objc func startSearch() { hotkeyPressed() }

    @objc func reloadPacks() {
        library = loadLibrary(config: config)
        model.packErrors = library.errors
        search.setSource(library: library)
        monitor.reload(library: library)
    }

    @objc func openPacks() {
        try? FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(packsDir)
    }

    @objc func openConfig() {
        let f = configDir.appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: f.path) {
            try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let c = Config(), k = c.coach, l = c.llm, v = c.vault
            try? """
            # Sanketa settings. Sanketa applies them when you save this file.
            # hotkey = "\(c.hotkey)"
            # pollInterval = \(c.pollInterval)
            # tipRotateSeconds = \(c.tipRotateSeconds)
            # translucency = "\(c.translucency.rawValue)"   # low, medium or high
            # hyper_label = "\(c.hyperLabel)"   # how Leela's Hyper key (⌃⌥⇧⌘) shows
            # terminals = [\(c.terminals.map { "\"\($0)\"" }.joined(separator: ", "))]

            # [coach]   # tips from your shell history; Sanketa reads it on this Mac only
            # enabled = \(k.enabled)
            # fish_history = "\(k.fishHistory)"
            # bash_history = "\(k.bashHistory)"
            # max_entries = \(k.maxEntries)

            # [llm]   # natural-language search; the model only chooses from entries that Sanketa loaded
            # on_device = \(l.onDevice)   # the model on this Mac; off until you choose a model in the On-Device Model menu
            # mlx_model = "\(l.mlxModel.rawValue)"   # one of: \(MLXModelChoice.allCases.map { "\($0.rawValue) (\($0.displayName))" }.joined(separator: ", "))
            # apple_fm = \(l.appleFM)   # Apple Intelligence, when it is on
            # suggest = \(l.suggest)   # on-device tips for the commands that you ran last
            # openai = \(l.openai)   # true: use an OpenAI server
            # openai_model = "\(l.openaiModel)"   # empty: the cheapest model
            # base_url = "\(l.baseURL)"
            # api_key_env = "OPENAI_API_KEY"   # read only for api.openai.com unless you set it
            # timeout_seconds = \(Int(l.timeoutSeconds))

            # [abhyasa]   # Abhyasa, the learning app; false: Sanketa never connects to it
            # enabled = \(c.abhyasa.enabled)   # Return opens vault results in Abhyasa when the app is installed or the server answers
            # url = "\(c.abhyasa.url)"   # the server, when the app is not installed: concepts at /c/<slug>, documents at /v/<shelf>/<doc_id>

            # [vault]   # search your vault too; Sanketa only reads it, on this Mac
            # enabled = \(v.enabled)   # on when the vault file exists; false: off
            # path = ""   # empty: VISHALAKSHI_VAULT, then ABHYASA_VAULT, then \(VaultConfig.defaultPath)
            # mcp = \(v.mcp)   # search by meaning and save notes with ⌘S and ⇧⌘S, through the vault server; Sanketa does not write the vault
            # mcp_command = ""   # the vault server; empty: the first of \(VaultConfig.mcpCandidates.joined(separator: ", "))
            # mcp_url = ""   # a vault server that runs on this Mac, such as http://127.0.0.1:8000/mcp; Sanketa then starts none
            # mcp_timeout_seconds = \(v.mcpTimeoutSeconds)   # then the word results show
            # mcp_idle_seconds = \(Int(v.mcpIdleSeconds))   # the server stops after this time with no search

            """.write(to: f, atomically: true, encoding: .utf8)
        }
        openForEditing(f)
    }

    /// Opens a pack or config file in the app that the user set for `.toml` files. With none, it opens in the default
    /// text editor, as `open -t` does. Sanketa starts no terminal and runs no `$EDITOR` command.
    func openForEditing(_ f: URL) {
        let ws = NSWorkspace.shared
        guard let app = ws.urlForApplication(toOpen: f) ?? ws.urlForApplication(toOpen: .plainText) else { return }
        ws.open([f], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func grantAccessibility() { AXReader.promptForTrust() }

    /// For a bug report: version, the app in front, layers, packs, Accessibility state and the model tiers. No file
    /// contents and no key: only where the key came from.
    @objc func copyDebugInfo() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let l = config.llm, r = llm.router
        let statuses: [(String, ModelStatus)] = [
            ("on-device", l.onDevice ? r.onDevice?.status() ?? .unavailable(mlxReady ? "model not downloaded" : "needs the MLX build") : .off),
            ("Apple Intelligence", l.appleFM ? r.appleFM?.status() ?? .unavailable("not set up") : .off),
        ]
        let (context, lib, path, err, keys) = (monitor.context, library, configURL.path, configError, l.openai ? llm.keys : nil)
        func copy(_ source: KeySource?, checked: Bool) -> Int {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(DebugInfo.report(version: version, context: context, library: lib, configPath: path, configError: err,
                                          llm: DebugInfo.llmLines(config: l, statuses: statuses, keySource: source, keyChecked: checked)),
                         forType: .string)
            return pb.changeCount
        }
        // the report is on the pasteboard at once; with OpenAI on, the key line says "checking…" until the lookup ends
        let copied = copy(nil, checked: keys == nil)
        guard let keys else { return }
        Task {
            let source = await keys.lookup()?.source
            // replace it only if nothing else was copied since
            if NSPasteboard.general.changeCount == copied { _ = copy(source, checked: true) }
        }
    }

    /// The vault search from `[vault]`: hybrid through the vault server when it can, else keyword only. Nothing when the
    /// vault file is missing. It opens the vault on the first search of 3 letters or more. The old MCP child stops.
    func applyVault() {
        hybrid?.client.close()
        if menuProbe == nil || menuProbe?.base != config.abhyasa.localURL {
            menuProbe = AbhyasaProbe(base: config.abhyasa.localURL, app: Self.abhyasaInstalled)
        }
        tools = currentTools()
        vault = VaultHybrid.make(config.vault, abhyasa: config.abhyasa, abhyasaApp: Self.abhyasaInstalled)
        search.setVault(vault?.search)
        search.setWriter(vault?.writer)
    }

    func applicationWillTerminate(_ n: Notification) { hybrid?.client.close() }

    // MARK: natural-language search

    /// A new router from `[llm]`; the key lookup and the model list stay when the server stays the same.
    func rebuildLLM() {
        let old = llm.baseURL
        llm = makeLLM(config.llm, previous: llm)
        search.setSmart(SmartSearch(router: llm.router, timeout: config.llm.timeoutSeconds))
        menus.llmChanged(oldBase: old)
    }

    /// Search started: load the model off the main thread, at most once a minute. With OpenAI on, also find the key
    /// (the login shell runs once per launch) and the model list (kept 10 minutes), so the first request is quick.
    func prewarm() {
        // the vault's MCP server needs about 1.5 seconds to start; it is ready, or near, when the query has 3 letters
        hybrid?.client.warm()
        guard prewarmGate.ready() else { return }
        let router = llm.router
        DispatchQueue.global(qos: .utility).async { router.prewarm() }
        guard config.llm.openai, let keys = llm.keys else { return }
        let models = config.llm.openaiModel.isEmpty ? llm.models : nil
        Task.detached(priority: .utility) {
            _ = await keys.key()
            _ = await models?.cheapest()
        }
    }

    /// After the history changed, at a local shell prompt, at most once per 10 minutes: up to 2 pack entries that an
    /// on-device model relates to the last commands. They join the coaching cards. History never goes to OpenAI.
    func suggestIfDue() {
        guard coach.generation != suggestGeneration, let l = monitor.context.layers.first, l.kind == .shell, l.host == nil,
              let shell = Shell(rawValue: l.name), llm.router.suggestChooser() != nil else { return }
        let recent = coach.recent(shell: shell, limit: ChoicePrompt.commandCount)
        guard !recent.isEmpty, suggestGate.ready() else { return }
        suggestGeneration = coach.generation
        let lib = library, router = llm.router, timeout = config.llm.timeoutSeconds, known = tips.ids(marked: .known)
        let items = lib.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
        Task { [weak self] in
            let picks = await SmartSuggest.pick(recent: recent, library: lib, items: items, excluding: known, router: router, timeout: timeout)
            guard let self else { return }
            suggestions = picks.map { var i = $0; i.explain = "Related to what you just ran"; i.tags.append(shell.rawValue); return i }
            model.coachItems = coach.items + suggestions
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}
