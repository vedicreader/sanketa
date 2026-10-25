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
