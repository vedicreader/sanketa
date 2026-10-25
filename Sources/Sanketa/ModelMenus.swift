import AppKit
import SanketaCore
import SanketaUI
import SanketaAI
import SanketaMLX

/// The "OpenAI Model", "OpenAI Key…" and "On-Device Model" status-menu items: the model list, the key box and the
/// model download. The app owns the config and the router; this asks it for them and tells it about a change.
@MainActor final class ModelMenus: NSObject, NSMenuDelegate {
    let modelMenu = NSMenu(), onDeviceMenu = NSMenu()
    private(set) var modelItem: NSMenuItem?, keyItem: NSMenuItem?
    let llm: () -> LLMSetup
    let config: () -> LLMConfig
    /// sets `[llm]` in the app's config and rebuilds the router
    let change: (LLMConfig) -> Void
    var modelLines: [MenuLine] = [], deviceLines: [MenuLine] = []
    /// the last model list that loaded, and the state of the load
    var modelIDs: [String]?
    var loadingModels = false
    var modelFailure: String?
    lazy var installer = ModelInstaller(root: ModelCatalog.defaultRoot)
    var downloadProgress: Double?
    var downloadError: String?

    init(llm: @escaping () -> LLMSetup, config: @escaping () -> LLMConfig, change: @escaping (LLMConfig) -> Void) {
        self.llm = llm; self.config = config; self.change = change
        super.init()
        for m in [modelMenu, onDeviceMenu] { m.delegate = self; m.autoenablesItems = false }
    }

    /// Adds the three items to the status menu.
    func add(to m: NSMenu) {
        let provider = llm().providerName
        modelItem = m.addItem(withTitle: StatusMenus.modelTitle(provider: provider), action: nil, keyEquivalent: "")
        modelItem?.submenu = modelMenu
        keyItem = m.addItem(withTitle: StatusMenus.keyTitle(provider: provider), action: #selector(enterKey), keyEquivalent: "")
        keyItem?.target = self
        m.addItem(withTitle: "On-Device Model", action: nil, keyEquivalent: "").submenu = onDeviceMenu
        // a submenu with no items does not open, so each gets its lines now; menuWillOpen refreshes them. The on-device
        // menu gets only its status line: the full menu looks for the MLX shaders, and that waits until the user opens it
        renderModelMenu()
        fill(onDeviceMenu, [MenuLine(config().onDevice ? StatusMenus.name(config().mlxModel) : StatusMenus.onDeviceOff, enabled: false)],
             #selector(pickDevice(_:)))
    }

    /// The router was rebuilt: new titles, and a new server forgets the old list.
    func llmChanged(oldBase: URL?) {
        let l = llm()
        if l.baseURL != oldBase { modelIDs = nil; modelFailure = nil }
        modelItem?.title = StatusMenus.modelTitle(provider: l.providerName)
        keyItem?.title = StatusMenus.keyTitle(provider: l.providerName)
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

    /// Runs `body` on the main thread in the common modes, so an open menu or a modal box updates.
    nonisolated func onMain(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated(body) }
    }

    // MARK: OpenAI model

    func renderModelMenu() {
        modelLines = StatusMenus.modelLines(config: config(), models: modelIDs, loading: loadingModels, failure: modelFailure)
        fill(modelMenu, modelLines, #selector(pickModel(_:)))
    }

    /// Shows the last list at once and loads a new one (8 s timeout); with OpenAI off, it sends nothing.
    func openModelMenu() {
        let l = llm()
        guard config().openai, let models = l.models, !loadingModels else { return renderModelMenu() }
        loadingModels = true
        modelFailure = nil
        renderModelMenu()
        let (base, provider) = (l.baseURL, l.providerName)
        Task.detached {
            var ids: [String]?, failure: String?
            do { ids = try await models.refresh() } catch { failure = StatusMenus.failure(error, provider: provider) }
            self.onMain {
                self.loadingModels = false
                guard self.llm().baseURL == base else { return }
                if let ids { self.modelIDs = ids }
                self.modelFailure = failure
                self.renderModelMenu()
            }
        }
    }

    /// Saves the pick as `[llm] openai_model`; "Cheapest" saves an empty value.
    @objc func pickModel(_ sender: NSMenuItem) {
        guard modelLines.indices.contains(sender.tag) else { return }
        var c = config()
        switch modelLines[sender.tag].action {
        case .cheapest: c.openaiModel = ""
        case .model(let m): c.openaiModel = m
        default: return
        }
        change(c)
        save("openai_model", c.openaiModel)
    }

    // MARK: key

    /// Opens the key box at once; its last line says where the key is when the lookup ends. A saved key goes through
    /// `APIKey.clean` into the Keychain.
    @objc func enterKey() {
        let l = llm()
        guard let url = l.baseURL, let keys = l.keys else {
            return KeyBox.tell("No server address", "Set base_url in [llm] in config.toml to an https address.")
        }
        let name = keys.varName ?? ""
        guard let typed = KeyBox.ask(host: OpenAIModels.host(url), status: {
            KeyBox.statusText(await keys.lookup()?.source, varName: name)
        }) else { return }
        guard let key = APIKey.clean(typed) else {
            return KeyBox.tell("Key not saved", "The key is empty, or it has spaces or control characters in it.")
        }
        do {
            try KeychainStore().write(key, account: APIKey.account(for: url))
            modelFailure = nil
            if let models = l.models { Task { await models.reset() } }
        } catch {
            KeyBox.tell("Key not saved", "\(error)")
        }
    }

    // MARK: on-device model

    func renderOnDeviceMenu() {
        let installed = Set(MLXModelChoice.allCases.filter { installer.isInstalled(ModelCatalog.spec($0)) })
        let failed = Set(MLXModelChoice.allCases.filter { MLXChooser.didFail(installer.directory(ModelCatalog.spec($0))) })
        deviceLines = StatusMenus.onDeviceLines(on: config().onDevice, selected: config().mlxModel, installed: installed,
                                                progress: downloadProgress, mlxReady: mlxReady, error: downloadError, failed: failed)
        fill(onDeviceMenu, deviceLines, #selector(pickDevice(_:)))
    }

    @objc func pickDevice(_ sender: NSMenuItem) {
        guard deviceLines.indices.contains(sender.tag) else { return }
        switch deviceLines[sender.tag].action {
        case .download(let c): download(c)
        case .use(let c): use(c)
        case .turnOff:
            var c = config()
            c.onDevice = false
            change(c)
            saveLLM("on_device", "false")
            Task { await MLXChooser.unloadAll() }
        case .remove:
            // the loaded model goes out of memory first, so no file is in use when it goes
            Task { @MainActor in
                await MLXChooser.unloadAll()
                for c in MLXModelChoice.allCases where installer.isInstalled(ModelCatalog.spec(c)) {
                    do { try installer.remove(ModelCatalog.spec(c)) } catch { downloadError = "Could not remove \(StatusMenus.name(c))." }
                }
                MLXChooser.forgetFailure(nil)
                // no model is left to use, so the on-device model goes off
                var c = config()
                c.onDevice = false
                change(c)
                saveLLM("on_device", "false")
                renderOnDeviceMenu()
            }
        default: break
        }
    }

    /// The user's choice: `m` becomes `[llm] mlx_model`, and `on_device` goes on.
    func use(_ m: MLXModelChoice) {
        var c = config()
        c.mlxModel = m
        c.onDevice = true
        change(c)
        save("mlx_model", m.rawValue)
        saveLLM("on_device", "true")
    }

    /// Downloads and checks the model; the status line shows the percent. When it is done, it becomes `[llm] mlx_model`.
    func download(_ m: MLXModelChoice) {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        downloadError = nil
        let installer = installer, spec = ModelCatalog.spec(m), steps = ProgressSteps(every: 1)
        Task.detached {
            var failure: String?
            do {
                try await installer.install(spec) { done, total in
                    guard let p = steps.next(done: done, total: total) else { return }
                    self.onMain {
                        guard self.downloadProgress != nil else { return }
                        self.downloadProgress = Double(p) / 100
                        self.renderOnDeviceMenu()
                    }
                }
            } catch {
                failure = (error as? InstallError)?.message ?? "The download stopped."
            }
            self.onMain {
                self.downloadProgress = nil
                self.downloadError = failure
                if failure == nil { MLXChooser.forgetFailure(installer.directory(spec)); self.use(m) }
                self.renderOnDeviceMenu()
            }
        }
    }

    /// Writes one `[llm]` key as a TOML string.
    func save(_ key: String, _ value: String) { saveLLM(key, tomlString(value)) }
}
