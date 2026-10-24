import Foundation
import SanketaCore

/// Text for `--dump-context` and the Copy Debug Info menu item.
public enum DebugInfo {
    /// The app, each layer with the rule that picked its pack, the title's scope token, and the packs.
    /// The window title shows only when `title` is given (the CLI); Copy Debug Info leaves it out.
    /// With `redact`, ssh host names show as `remote host`.
    public static func context(_ c: Context, title: String? = nil, showTitle: Bool = false, redact: Bool = false) -> [String] {
        func host(_ h: String) -> String { redact ? "remote host" : h }
        let scope = c.packs.lazy.compactMap { $0.scopeToken(title: title) }.first
        let active = c.layers.compactMap(\.context).first
        let head = ["app: \(c.appName) (\(c.bundleID)) axTrusted=\(c.axTrusted)"]
            + (showTitle ? ["title: \(title.map { "\"\($0)\"" } ?? "none") scope=\(scope ?? "-") context=\(active ?? "-")"] : [])
        let layers = c.layers.map { l in
            "  \(l.kind.rawValue) \(l.kind == .remote ? host(l.name) : l.name) pack=\(l.packID ?? "-")" + (l.host.map { " host=\(host($0))" } ?? "")
                + (l.context.map { " context=\($0)" } ?? "") + (l.reason.map { " via \($0)" } ?? "")
        }
        let packs = c.packs.map { "  \($0.id) keys=\($0.keys.count) tips=\($0.tips.count)\($0.prefix.map { " prefix=\($0)" } ?? "")" }
        return head + ["layers:"] + layers + ["packs:"] + packs
    }

    /// One line for the stack, for `--watch`: `htop › tmux › fish › Kaku`.
    public static func stack(_ c: Context) -> String { c.layers.map(\.name).joined(separator: " › ") }

    /// Version, macOS, config and pack state and the context. No file contents and no pack file names (only their count),
    /// ssh hosts show as `remote host`, and the home folder shows as `~`.
    public static func report(version: String, context c: Context, library: PackLibrary, configPath: String, configError: String?,
                              home: String = NSHomeDirectory(), llm: [String] = []) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let lines = ["Sanketa \(version) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                     "config: \(configPath)" + (configError.map { " (did not load: \($0))" } ?? ""),
                     "packs loaded: \(library.packs.count), pack files that did not load: \(library.errors.count)"] + context(c, redact: true) + llm
        return tilde(lines.joined(separator: "\n"), home: home) + "\n"
    }

    /// The model tiers: `on-device: <status>`, `Apple Intelligence: <status>`, then `openai: off`, or `openai: on
    /// provider=openai|custom model=<id or auto>` and where the key came from. It never takes the key, and it never
    /// shows the address of a custom server.
    public static func llmLines(config: LLMConfig, statuses: [(String, ModelStatus)], keySource: KeySource? = nil) -> [String] {
        func text(_ s: ModelStatus) -> String {
            switch s {
            case .available: "available"
            case .off: "off"
            case .unavailable(let why): "unavailable (\(why))"
            }
        }
        let tiers = statuses.map { "\($0.0): \(text($0.1))" }
        guard config.openai else { return tiers + ["openai: off"] }
        let openAI = URL(string: config.baseURL).map(OpenAIModels.isOpenAI) ?? false
        return tiers + ["openai: on provider=\(openAI ? "openai" : "custom") model=\(config.openaiModel.isEmpty ? "auto" : config.openaiModel)",
                        "OpenAI key: " + (keySource.map { "found (\($0.rawValue))" } ?? "missing")]
    }

    static func tilde(_ s: String, home: String) -> String {
        home.isEmpty || home == "/" ? s : s.replacingOccurrences(of: home, with: "~")
    }
}
