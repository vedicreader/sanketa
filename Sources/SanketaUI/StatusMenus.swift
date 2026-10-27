import Foundation
import SanketaCore

/// One status-menu line and what a click on it does.
public struct MenuLine: Equatable {
    public enum Action: Equatable { case none, cheapest, model(String), download(MLXModelChoice), use(MLXModelChoice), turnOff, remove }
    public var title: String
    public var enabled: Bool
    public var checked = false
    public var action: Action = .none

    public init(_ title: String, enabled: Bool = true, checked: Bool = false, action: Action = .none) {
        self.title = title; self.enabled = enabled; self.checked = checked; self.action = action
    }
}

/// The lines of the "OpenAI Model" and "On-Device Model" submenus.
public enum StatusMenus {
    public static let turnOn = "Turn on Use OpenAI first"
    public static let loading = "Loading models…"
    public static let failed = "Could not load the model list"

    /// The model-menu line when the list did not load because there is no key.
    public static func noKey(provider: String) -> String { "No API key. Choose \(keyTitle(provider: provider))" }

    /// The model-menu line for a list that did not load.
    public static func failure(_ e: Error, provider: String) -> String {
        (e as? ChoiceError) == .noKey ? noKey(provider: provider) : failed
    }
    public static let needsMLX = "Needs the MLX build"

    /// "OpenAI Model", or "Model (host)" for another server.
    public static func modelTitle(provider: String) -> String { provider == "OpenAI" ? "OpenAI Model" : "Model (\(provider))" }

    /// "OpenAI Key…", or "API Key (host)…" for another server.
    public static func keyTitle(provider: String) -> String { provider == "OpenAI" ? "OpenAI Key…" : "API Key (\(provider))…" }

    /// With OpenAI off, one disabled line and no request. Else "Cheapest (now <name>)", then the models in the list, by the
    /// names that people know (`OpenAIModels.displayName`); the saved choice is checked. A saved id that is not in the list still shows. `failure` is why the last load failed.
    public static func modelLines(config: LLMConfig, models: [String]?, loading: Bool, failure: String?) -> [MenuLine] {
        guard config.openai else { return [MenuLine(turnOn, enabled: false)] }
        let pinned = config.openaiModel
        let cheapest = models.flatMap(OpenAIModels.cheapest)
        var out = [MenuLine(cheapest.map { "Cheapest (now \(OpenAIModels.displayName($0)))" } ?? "Cheapest", checked: pinned.isEmpty,
                            action: .cheapest)]
        var ids = models ?? []
        if !pinned.isEmpty && !ids.contains(pinned) { ids.insert(pinned, at: 0) }
        out += ids.map { MenuLine(OpenAIModels.displayName($0), checked: $0 == pinned, action: .model($0)) }
        if loading { out.append(MenuLine(StatusMenus.loading, enabled: false)) }
        else if let failure { out.append(MenuLine(failure, enabled: false)) }
        return out
    }

    public static func name(_ c: MLXModelChoice) -> String { c.displayName }

    /// Bytes as gigabytes with one decimal, e.g. "3.1 GB".
    public static func size(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// The status line while no on-device model is in use.
    public static let onDeviceOff = "Not in use. Search does not use an on-device model."
    public static let noOnDevice = "No On-Device Model"

    /// A status line, then a line per catalog model that fits in `memory`, "No On-Device Model" and "Remove Downloaded
    /// Models". With `on` false no model is in use, and "No On-Device Model" is checked. Downloads need the MLX build
    /// (`mlxReady`, asked only when a download line shows); until then a disabled line says so. During a download the
    /// status line shows the percent. `error` is why the last download failed, on its own disabled line. `failed` are the
    /// models that did not load; then the fallback model shows too. Below `MLXModelChoice.memoryFloor` there is one
    /// line that says so, and no model lines.
    public static func onDeviceLines(on: Bool = true, selected: MLXModelChoice, installed: Set<MLXModelChoice>, progress: Double?,
                                     mlxReady: @autoclosure () -> Bool, error: String? = nil,
                                     memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                                     failed: Set<MLXModelChoice> = []) -> [MenuLine] {
        let idle = progress == nil
        guard MLXModelChoice.anyFits(memory: memory) else {
            var out = [MenuLine(MLXModelChoice.notEnoughMemory, enabled: false)]
            if !installed.isEmpty { out.append(MenuLine("Remove Downloaded Models", enabled: idle, action: .remove)) }
            return out
        }
        let state = failed.contains(selected) ? "did not load" : installed.contains(selected) ? "downloaded" : "not downloaded"
        let status = progress.map { "Downloading… \(Int(($0 * 100).rounded(.down))) %" } ?? (on ? "\(name(selected)): \(state)" : onDeviceOff)
        var out = [MenuLine(status, enabled: false)]
        if let error, progress == nil { out.append(MenuLine(error, enabled: false)) }
        let shown = MLXModelChoice.allCases.filter { c in
            memory >= c.minMemory && (!c.isFallback || !failed.isEmpty || installed.contains(c) || (on && c == selected))
        }
        let ready = shown.allSatisfy(installed.contains) || mlxReady()
        if !ready { out.append(MenuLine(needsMLX, enabled: false)) }
        for c in shown {
            let current = on && c == selected
            if installed.contains(c) {
                out.append(MenuLine("Use \(name(c))", enabled: idle && !current, checked: current, action: .use(c)))
            } else {
                out.append(MenuLine("Download \(name(c)) (\(size(ModelCatalog.spec(c).downloadSize)))", enabled: idle && ready,
                                    action: .download(c)))
            }
        }
        out.append(MenuLine(noOnDevice, enabled: idle && on, checked: !on, action: .turnOff))
        out.append(MenuLine("Remove Downloaded Models", enabled: idle && !installed.isEmpty, action: .remove))
        return out
    }
}

/// The three toggles of the status menu that connect Sanketa to other tools, and "Set Up the Vault…". Each toggle writes
/// one key: `[vault] enabled`, `[vault] mcp` and `[abhyasa] enabled`. A missing key means "on when the tool is there";
/// only `false` turns a tool off. A missing vault file or server shows as a disabled line that tells what it needs. A
/// missing Abhyasa app shows as "Get the Abhyasa App…", which opens its download page.
public enum VaultToggles {
    public enum Key: String, CaseIterable, Sendable { case vault, hybrid, abhyasa, setup }

    public static let vaultTitle = "Search the Vault"
    public static let hybridTitle = "Search by Meaning, Save Notes"
    public static let abhyasaTitle = "Open in Abhyasa"
    public static let setupTitle = "Set Up the Vault…"
    public static let noVaultFile = "Search the Vault (no vault file)"
    public static let noServer = "Search by Meaning (needs the vault server)"
    /// with no Abhyasa app, the Abhyasa line opens the download section of the Abhyasa README
    public static let noAbhyasa = "Get the Abhyasa App…"
    public static let abhyasaDownload = URL(string: "https://github.com/vedicreader/abhyasa#download")!

    /// One line for each toggle, and "Set Up the Vault…" when the vault server is missing. A check mark shows only when the
    /// tool is on and there. The two vault options need vault search on. Saving needs no vault file: the first note makes
    /// it. Opening in abhyasa needs the file.
    public static func lines(_ c: Config, _ t: VaultTools, settingUp: Bool = false) -> [(key: Key, line: MenuLine)] {
        let vault = c.vault.enabled && t.vaultFile, on = c.vault.enabled
        var out: [(key: Key, line: MenuLine)] = [
            (.vault, t.vaultFile ? MenuLine(vaultTitle, checked: vault) : MenuLine(noVaultFile, enabled: false)),
            (.hybrid, t.server ? MenuLine(hybridTitle, enabled: on, checked: on && c.vault.mcp) : MenuLine(noServer, enabled: false)),
            (.abhyasa, t.abhyasa ? MenuLine(abhyasaTitle, enabled: vault, checked: vault && c.abhyasa.enabled) : MenuLine(noAbhyasa)),
        ]
        if !t.server { out.append((.setup, MenuLine(settingUp ? "Setting Up the Vault…" : setupTitle, enabled: !settingUp))) }
        return out
    }

    /// The table, key and TOML value that a click on `key` saves; nil for "Set Up the Vault…".
    public static func change(_ key: Key, _ c: Config) -> (table: String, key: String, value: String)? {
        switch key {
        case .vault: return ("vault", "enabled", c.vault.enabled ? "false" : "true")
        case .hybrid: return ("vault", "mcp", c.vault.mcp ? "false" : "true")
        case .abhyasa: return ("abhyasa", "enabled", c.abhyasa.enabled ? "false" : "true")
        case .setup: return nil
        }
    }
}

/// "Set Up the Vault…": gets the vault server with `uv tool install vishalakshi`, only after the user agrees.
public enum VaultSetup {
    /// Where Sanketa looks for uv, in this order.
    public static let uvCandidates = ["/opt/homebrew/bin/uv", "~/.local/bin/uv", "/usr/local/bin/uv"]

    /// The first uv that `exists`, `~` expanded; nil: none.
    public static func findUV(exists: (String) -> Bool = FileManager.default.isExecutableFile) -> String? {
        uvCandidates.map { ($0 as NSString).expandingTildeInPath }.first(where: exists)
    }

    /// The arguments for uv.
    public static let arguments = ["tool", "install", "vishalakshi"]

    public static let title = "Set Up the Vault"

    /// The text of the question, with uv, or of the note, without uv.
    public static func message(uv: String?) -> String {
        guard uv != nil else {
            return "Sanketa uses uv to get the vault server. Sanketa cannot find uv. Install uv with \"brew install uv\". Then try again."
        }
        return "Sanketa will run \"uv tool install vishalakshi\". This command gets the vault server from the internet. "
            + "Then Sanketa can search by meaning and save notes. Sanketa does not change your vault."
    }

    public static let started = "Setting up the vault…"
    public static let done = "The vault server is ready."
    public static let failed = "Sanketa could not set up the vault server. Run \"uv tool install vishalakshi\" in a terminal to see why."

    /// Runs uv with `runner` (up to 10 minutes) and gives the toast text for the result.
    public static func run(uv: String, runner: CommandRunning) -> String {
        runner.run(uv, arguments, timeout: 600) == nil ? failed : done
    }
}
