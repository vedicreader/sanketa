import Foundation
import SanketaCore

/// One status-menu line and what a click on it does.
public struct MenuLine: Equatable {
    public enum Action: Equatable { case none, cheapest, model(String), download(MLXModelChoice), use(MLXModelChoice), remove }
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
    public static let turnOn = "Turn on with [llm] openai = true in config.toml"
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

    /// With OpenAI off, one disabled line and no request. Else "Cheapest (now <id>)", then the ids in the list; the
    /// saved choice is checked. A saved id that is not in the list still shows. `failure` is why the last load failed.
    public static func modelLines(config: LLMConfig, models: [String]?, loading: Bool, failure: String?) -> [MenuLine] {
        guard config.openai else { return [MenuLine(turnOn, enabled: false)] }
        let pinned = config.openaiModel
        let cheapest = models.flatMap(OpenAIModels.cheapest)
        var out = [MenuLine(cheapest.map { "Cheapest (now \($0))" } ?? "Cheapest", checked: pinned.isEmpty, action: .cheapest)]
        var ids = models ?? []
        if !pinned.isEmpty && !ids.contains(pinned) { ids.insert(pinned, at: 0) }
        out += ids.map { MenuLine($0, checked: $0 == pinned, action: .model($0)) }
        if loading { out.append(MenuLine(StatusMenus.loading, enabled: false)) }
        else if let failure { out.append(MenuLine(failure, enabled: false)) }
        return out
    }

    public static func name(_ c: MLXModelChoice) -> String { c.displayName }

    /// Bytes as gigabytes with one decimal, e.g. "3.1 GB".
    public static func size(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// A status line for the chosen model, then a line per catalog model and "Remove Downloaded Models". Downloads need
    /// the MLX build (`mlxReady`); until then a disabled line says so. During a download the status line shows the percent.
    /// `error` is why the last download failed, on its own disabled line. A model that needs more than `memory` shows
    /// only when it is downloaded.
    public static func onDeviceLines(selected: MLXModelChoice, installed: Set<MLXModelChoice>, progress: Double?,
                                     mlxReady: Bool, error: String? = nil,
                                     memory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> [MenuLine] {
        let status = progress.map { "Downloading… \(Int(($0 * 100).rounded(.down))) %" }
            ?? "\(name(selected)): " + (installed.contains(selected) ? "downloaded" : "not downloaded")
        var out = [MenuLine(status, enabled: false)]
        if let error, progress == nil { out.append(MenuLine(error, enabled: false)) }
        if !mlxReady { out.append(MenuLine(needsMLX, enabled: false)) }
        let idle = progress == nil
        for c in MLXModelChoice.allCases where installed.contains(c) || memory >= c.minMemory {
            if installed.contains(c) {
                out.append(MenuLine("Use \(name(c))", enabled: idle && c != selected, checked: c == selected, action: .use(c)))
            } else {
                out.append(MenuLine("Download \(name(c)) (\(size(ModelCatalog.spec(c).downloadSize)))", enabled: idle && mlxReady,
                                    action: .download(c)))
            }
        }
        out.append(MenuLine("Remove Downloaded Models", enabled: idle && !installed.isEmpty, action: .remove))
        return out
    }
}
