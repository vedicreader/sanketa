import Foundation
import SanketaCore

/// Text for `--dump-context` and the Copy Debug Info menu item.
public enum DebugInfo {
    /// The app, each layer with the rule that picked its pack, the title's scope token, and the packs.
    /// The window title shows only when `title` is given (the CLI); Copy Debug Info leaves it out.
    public static func context(_ c: Context, title: String? = nil, showTitle: Bool = false) -> [String] {
        let scope = c.packs.lazy.compactMap { $0.scopeToken(title: title) }.first
        let active = c.layers.compactMap(\.context).first
        let head = ["app: \(c.appName) (\(c.bundleID)) axTrusted=\(c.axTrusted)"]
            + (showTitle ? ["title: \(title.map { "\"\($0)\"" } ?? "none") scope=\(scope ?? "-") context=\(active ?? "-")"] : [])
        let layers = c.layers.map { l in
            "  \(l.kind.rawValue) \(l.name) pack=\(l.packID ?? "-")" + (l.host.map { " host=\($0)" } ?? "")
                + (l.context.map { " context=\($0)" } ?? "") + (l.reason.map { " via \($0)" } ?? "")
        }
        let packs = c.packs.map { "  \($0.id) keys=\($0.keys.count) tips=\($0.tips.count)\($0.prefix.map { " prefix=\($0)" } ?? "")" }
        return head + ["layers:"] + layers + ["packs:"] + packs
    }

    /// One line for the stack, for `--watch`: `htop › tmux › fish › Kaku`.
    public static func stack(_ c: Context) -> String { c.layers.map(\.name).joined(separator: " › ") }

    /// Version, macOS, config and pack state and the context. No file contents, and the home folder shows as `~`.
    public static func report(version: String, context c: Context, library: PackLibrary, configPath: String, configError: String?,
                              home: String = NSHomeDirectory()) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let errors = library.errors.map { "  \(($0.file as NSString).lastPathComponent): \($0.message)" }
        let lines = ["Sanketa \(version) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                     "config: \(configPath)" + (configError.map { " (did not load: \($0))" } ?? ""),
                     "packs loaded: \(library.packs.count), pack errors: \(errors.count)"] + errors + context(c)
        return tilde(lines.joined(separator: "\n"), home: home) + "\n"
    }

    static func tilde(_ s: String, home: String) -> String {
        home.isEmpty || home == "/" ? s : s.replacingOccurrences(of: home, with: "~")
    }
}
