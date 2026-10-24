import AppKit
import UniformTypeIdentifiers
import Combine
import SanketaCore
import SanketaSystem
import SanketaUI
import SanketaAI

let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Sanketa")

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var config: Config
    /// why config.toml did not load, for the footer and Copy Debug Info
    var configError: String?
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
    /// model suggestions run at most once per 10 minutes, and only after the history changed
    let suggestGate = Throttle(600)
    var suggestGeneration = -1
    var suggestions: [SearchItem] = []
    var modelMenu = NSMenu(), onDeviceMenu = NSMenu()
    var modelMenuItem: NSMenuItem?, keyMenuItem: NSMenuItem?
    var modelLines: [MenuLine] = [], deviceLines: [MenuLine] = []
    /// the last model list the menu loaded, and its state
    var modelIDs: [String]?
    var loadingModels = false, modelsFailed = false
    lazy var installer = ModelInstaller(root: ModelCatalog.defaultRoot)
    var downloadProgress: Double?
    var downloadError: String?
    lazy var panel = PanelController(model: model, search: search, hotkeyLabel: Theme.display(hotkey: config.hotkey))
    let hotkeys = HotkeyCenter()
    var status: NSStatusItem?
    var subs = Set<AnyCancellable>()
    var rotation: Timer?
    var searchItem: NSMenuItem?
    /// Leela's keys.json, the user packs folder and config.toml: a save applies without a restart
    var watchers: [FileWatcher] = []

    override init() {
        (config, configError) = readConfig()
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
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
        panel.prewarm = { [weak self] in self?.prewarm() }
        registerHotkey()
        panel.grantAccessibility = { [weak self] in self?.grantAccessibility() }
        panel.openFile = { [weak self] in self?.openForEditing(URL(fileURLWithPath: $0)) }
        panel.makePack = { [weak self] layer in
            do { self?.openForEditing(try PackStarter.make(for: layer, in: packsDir)) }
            catch { FileHandle.standardError.write(Data("cannot make a pack for \(layer.name): \(error.localizedDescription)\n".utf8)) }
        }
        panel.setTranslucency(config.translucency)
        scheduleRotation()
        buildStatusItem()
        model.configError = configError.map { PackLoadError(file: configURL.path, message: $0) }
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
        (config, configError) = readConfig()
        model.configError = configError.map { PackLoadError(file: configURL.path, message: $0) }
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
        for sub in [modelMenu, onDeviceMenu] { sub.delegate = self; sub.autoenablesItems = false }
        modelMenuItem = m.addItem(withTitle: StatusMenus.modelTitle(provider: llm.providerName), action: nil, keyEquivalent: "")
        modelMenuItem?.submenu = modelMenu
        add(StatusMenus.keyTitle(provider: llm.providerName), #selector(enterKey))
        keyMenuItem = m.items.last
        m.addItem(withTitle: "On-Device Model", action: nil, keyEquivalent: "").submenu = onDeviceMenu
        // a submenu with no items does not open, so each gets its lines now; menuWillOpen refreshes them
        renderModelMenu()
        renderOnDeviceMenu()
        m.addItem(.separator())
        add("Reload Packs", #selector(reloadPacks))
        add("Open Packs Folder", #selector(openPacks))
        add("Open Config", #selector(openConfig))
        add("Allow Accessibility…", #selector(grantAccessibility))
        add("Copy Debug Info", #selector(copyDebugInfo))
        m.addItem(.separator())
        add("Quit Sanketa", #selector(quit))
        s.menu = m
        status = s
    }

    @objc func togglePanel() { panel.toggle() }

    /// Applies live and writes just `translucency` back to config.toml.
    @objc func pickTranslucency(_ sender: NSMenuItem) {
        guard let t = (sender.representedObject as? String).flatMap(Translucency.init) else { return }
        config.translucency = t
        panel.setTranslucency(t)
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        do { try Config.save("translucency", "\"\(t.rawValue)\"", to: configURL) }
        catch { FileHandle.standardError.write(Data("cannot save config: \(error.localizedDescription)\n".utf8)) }
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
            let c = Config(), k = c.coach, l = c.llm
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

            # [llm]   # natural-language search; the model only picks from entries that Sanketa loaded
            # on_device = \(l.onDevice)   # MLX model on this Mac
            # mlx_model = "\(l.mlxModel.rawValue)"   # or "\(MLXModelChoice.qwen2b.rawValue)"
            # apple_fm = \(l.appleFM)   # Apple Foundation Models
            # suggest = \(l.suggest)   # model tips in the tip slot
            # openai = \(l.openai)   # opt in: an OpenAI-compatible server
            # openai_model = "\(l.openaiModel)"   # empty: the cheapest model
            # base_url = "\(l.baseURL)"
            # api_key_env = "\(l.apiKeyEnv)"
            # timeout_seconds = \(Int(l.timeoutSeconds))

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
        Task {
            let source = await keys?.lookup()?.source
            let text = DebugInfo.report(version: version, context: context, library: lib, configPath: path, configError: err,
                                        llm: DebugInfo.llmLines(config: l, statuses: statuses, keySource: source))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: natural-language search

    /// A new router from `[llm]`; the key lookup and the model list stay when the server stays the same.
    func rebuildLLM() {
        let old = llm.baseURL
        llm = makeLLM(config.llm, previous: llm)
        search.setSmart(SmartSearch(router: llm.router, timeout: config.llm.timeoutSeconds))
        if llm.baseURL != old { modelIDs = nil; modelsFailed = false }
        modelMenuItem?.title = StatusMenus.modelTitle(provider: llm.providerName)
        keyMenuItem?.title = StatusMenus.keyTitle(provider: llm.providerName)
    }

    /// Search started: load the model off the main thread, at most once a minute. With OpenAI on, also find the key
    /// (the login shell runs once per launch) and the model list (kept 10 minutes), so the first request is quick.
    func prewarm() {
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

    func menuWillOpen(_ menu: NSMenu) {
        if menu === modelMenu { openModelMenu() } else if menu === onDeviceMenu { renderOnDeviceMenu() }
    }

    /// Lines with `tag` = index into `lines`; a click calls `action`.
    func fill(_ menu: NSMenu, _ lines: [MenuLine], _ action: Selector) {
        menu.removeAllItems()
        for (i, l) in lines.enumerated() {
            let item = menu.addItem(withTitle: l.title, action: l.action == .none ? nil : action, keyEquivalent: "")
            item.target = self
            item.tag = i
            item.isEnabled = l.enabled
            item.state = l.checked ? .on : .off
        }
    }

    func renderModelMenu() {
        modelLines = StatusMenus.modelLines(config: config.llm, models: modelIDs, loading: loadingModels, failed: modelsFailed)
        fill(modelMenu, modelLines, #selector(pickModel(_:)))
    }

    /// Shows the last list at once and loads a new one (8 s timeout); with OpenAI off, it sends nothing. The answer
    /// comes back through the main run loop in the common modes, so the open menu updates.
    func openModelMenu() {
        guard config.llm.openai, let models = llm.models, !loadingModels else { return renderModelMenu() }
        loadingModels = true
        modelsFailed = false
        renderModelMenu()
        let base = llm.baseURL
        Task.detached {
            var ids: [String]?
            do { ids = try await models.refresh() } catch { ids = nil }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.loadingModels = false
                    guard self.llm.baseURL == base else { return }
                    if let ids { self.modelIDs = ids } else { self.modelsFailed = true }
                    self.renderModelMenu()
                }
            }
        }
    }

    /// Saves the pick as `[llm] openai_model`; "Cheapest" saves an empty value.
    @objc func pickModel(_ sender: NSMenuItem) {
        guard modelLines.indices.contains(sender.tag) else { return }
        let id: String
        switch modelLines[sender.tag].action {
        case .cheapest: id = ""
        case .model(let m): id = m
        default: return
        }
        config.llm.openaiModel = id
        rebuildLLM()
        save("openai_model", tomlString(id), table: "llm")
    }

    /// Asks for a key and keeps it in the Keychain. A key from the environment or the login shell wins, so the box says so.
    @objc func enterKey() {
        guard let url = llm.baseURL, let keys = llm.keys else {
            return KeyBox.tell("No server address", "Set base_url in [llm] in config.toml to an https address.")
        }
        let name = config.llm.apiKeyEnv, models = llm.models
        Task {
            let source = await keys.lookup()?.source
            let note = source == .environment || source == .shell
                ? "Your shell sets \(name). Sanketa uses that key first. It uses a key that you save here only when \(name) is empty."
                : nil
            guard let typed = KeyBox.ask(host: OpenAIModels.host(url), note: note) else { return }
            guard let key = APIKey.clean(typed) else {
                return KeyBox.tell("Key not saved", "The key is empty, or it has spaces or control characters in it.")
            }
            do {
                try KeychainStore().write(key, account: APIKey.account(for: url))
                await models?.reset()
                modelsFailed = false
            } catch {
                KeyBox.tell("Key not saved", "\(error)")
            }
        }
    }

    func renderOnDeviceMenu() {
        let installed = Set(MLXModelChoice.allCases.filter { installer.isInstalled(ModelCatalog.spec($0)) })
        deviceLines = StatusMenus.onDeviceLines(selected: config.llm.mlxModel, installed: installed, progress: downloadProgress,
                                                mlxReady: mlxReady, error: downloadError)
        fill(onDeviceMenu, deviceLines, #selector(pickDevice(_:)))
    }

    @objc func pickDevice(_ sender: NSMenuItem) {
        guard deviceLines.indices.contains(sender.tag) else { return }
        switch deviceLines[sender.tag].action {
        case .download(let c): download(c)
        case .use(let c): useModel(c)
        case .remove:
            for c in MLXModelChoice.allCases where installer.isInstalled(ModelCatalog.spec(c)) {
                do { try installer.remove(ModelCatalog.spec(c)) }
                catch { downloadError = "Could not remove \(StatusMenus.name(c))." }
            }
            rebuildLLM()
        default: break
        }
    }

    func useModel(_ c: MLXModelChoice) {
        config.llm.mlxModel = c
        rebuildLLM()
        save("mlx_model", tomlString(c.rawValue), table: "llm")
    }

    /// Downloads and checks the model; progress shows in the status line. When it is done, it becomes `[llm] mlx_model`.
    func download(_ c: MLXModelChoice) {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        downloadError = nil
        let installer = installer, spec = ModelCatalog.spec(c)
        final class Percent: @unchecked Sendable {
            private let lock = NSLock()
            private var last = -1
            func changed(_ p: Int) -> Bool { lock.withLock { guard p != last else { return false }; last = p; return true } }
        }
        let percent = Percent()
        Task.detached {
            var failure: String?
            do {
                try await installer.install(spec) { done, total in
                    let f = Double(done) / Double(max(total, 1))
                    guard percent.changed(Int(f * 100)) else { return }
                    RunLoop.main.perform(inModes: [.common]) {
                        MainActor.assumeIsolated {
                            guard self.downloadProgress != nil else { return }
                            self.downloadProgress = f
                            self.renderOnDeviceMenu()
                        }
                    }
                }
            } catch {
                failure = (error as? InstallError)?.message ?? "The download stopped."
            }
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.downloadProgress = nil
                    self.downloadError = failure
                    if failure == nil { self.useModel(c) }
                    self.renderOnDeviceMenu()
                }
            }
        }
    }

    /// A TOML basic string.
    func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func save(_ key: String, _ value: String, table: String? = nil) {
        do { try Config.save(key, value, to: configURL, table: table) }
        catch { FileHandle.standardError.write(Data("cannot save config: \(error.localizedDescription)\n".utf8)) }
    }

    @objc func quit() { NSApp.terminate(nil) }
}
