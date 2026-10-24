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
    public static let needsMLX = "Needs the MLX build"

    /// "OpenAI Model", or "Model (host)" for another server.
    public static func modelTitle(provider: String) -> String { provider == "OpenAI" ? "OpenAI Model" : "Model (\(provider))" }

    /// "OpenAI Key…", or "API Key (host)…" for another server.
    public static func keyTitle(provider: String) -> String { provider == "OpenAI" ? "OpenAI Key…" : "API Key (\(provider))…" }

    /// With OpenAI off, one disabled line and no request. Else "Cheapest (now <id>)", then the ids in the list; the
    /// saved choice is checked. A saved id that is not in the list still shows.
    public static func modelLines(config: LLMConfig, models: [String]?, loading: Bool, failed didFail: Bool) -> [MenuLine] {
        guard config.openai else { return [MenuLine(turnOn, enabled: false)] }
        let pinned = config.openaiModel
        let cheapest = models.flatMap(OpenAIModels.cheapest)
        var out = [MenuLine(cheapest.map { "Cheapest (now \($0))" } ?? "Cheapest", checked: pinned.isEmpty, action: .cheapest)]
        var ids = models ?? []
        if !pinned.isEmpty && !ids.contains(pinned) { ids.insert(pinned, at: 0) }
        out += ids.map { MenuLine($0, checked: $0 == pinned, action: .model($0)) }
        if loading { out.append(MenuLine(StatusMenus.loading, enabled: false)) }
        else if didFail { out.append(MenuLine(failed, enabled: false)) }
        return out
    }

    public static func name(_ c: MLXModelChoice) -> String {
        switch c {
        case .qwen4b: "Qwen3.5-4B"
        case .qwen2b: "Qwen3.5-2B"
        }
    }

    /// Bytes as gigabytes with one decimal, e.g. "3.1 GB".
    public static func size(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// A status line for the chosen model, then a line per catalog model and "Remove Downloaded Models". Downloads need
    /// the MLX build (`mlxReady`); until then a disabled line says so. During a download the status line shows the percent.
    /// `error` is why the last download failed, on its own disabled line.
    public static func onDeviceLines(selected: MLXModelChoice, installed: Set<MLXModelChoice>, progress: Double?,
                                     mlxReady: Bool, error: String? = nil) -> [MenuLine] {
        let status = progress.map { "Downloading… \(Int(($0 * 100).rounded(.down))) %" }
            ?? "\(name(selected)): " + (installed.contains(selected) ? "downloaded" : "not downloaded")
        var out = [MenuLine(status, enabled: false)]
        if let error, progress == nil { out.append(MenuLine(error, enabled: false)) }
        if !mlxReady { out.append(MenuLine(needsMLX, enabled: false)) }
        let idle = progress == nil
        for c in MLXModelChoice.allCases {
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
