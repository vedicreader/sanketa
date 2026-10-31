import Foundation

/// Asks Kaku's own CLI (`kaku cli`, as in WezTerm) which pane has focus. Both commands only read.
public struct KakuQuery {
    let runner: CommandRunning
    /// the `kaku` binary inside the running app's bundle
    let cli: String
    public init(runner: CommandRunning, cli: String) { self.runner = runner; self.cli = cli }

    /// `Kaku.app/Contents/MacOS/kaku` for a Kaku bundle, when it is there
    public static func cli(bundle: URL?) -> String? {
        guard let path = bundle?.appendingPathComponent("Contents/MacOS/kaku").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    struct Client: Decodable { var pid: Int32?; var focused_pane_id: Int? }
    struct Pane: Decodable { var window_id: Int?; var tab_id: Int?; var pane_id: Int; var is_active: Bool?; var tty_name: String? }

    /// The focused pane id of the GUI `pid`, from `list-clients --format json`.
    public static func focusedPane(clients json: String, pid: Int32) -> Int? {
        guard let cs = try? JSONDecoder().decode([Client].self, from: Data(json.utf8)) else { return nil }
        return (cs.first { $0.pid == pid } ?? (cs.count == 1 ? cs[0] : nil))?.focused_pane_id
    }

    /// The tty (`ttys010`) of the tab the window shows, from `list --format json`. Another program's `kaku cli` command
    /// can move the focused pane `focused` to a tab that is not shown, so it only picks the window, and the title's
    /// `[n/m]` picks the n-th tab in Kaku's order. When the focused pane's window does not have m tabs, the only window
    /// that has m tabs is the one shown. Without a prefix that fits one window, or without window and tab ids in the
    /// list, the focused pane's tty.
    public static func shownTTY(list json: String, focused: Int, title: String?) -> String? {
        guard let ps = try? JSONDecoder().decode([Pane].self, from: Data(json.utf8)),
              let f = ps.first(where: { $0.pane_id == focused }) else { return nil }
        func tty(_ p: Pane) -> String? { p.tty_name.map { $0.replacingOccurrences(of: "/dev/", with: "") } }
        guard ps.allSatisfy({ $0.window_id != nil && $0.tab_id != nil }), let fw = f.window_id,
              let idx = title.flatMap(LayerResolver.splitTabIndex), 1 <= idx.n, idx.n <= idx.m else { return tty(f) }
        func tabs(_ window: Int) -> [Int] {
            var seen = Set<Int>()
            return ps.filter { $0.window_id == window }.compactMap(\.tab_id).filter { seen.insert($0).inserted }
        }
        let fits = Set(ps.compactMap(\.window_id)).filter { tabs($0).count == idx.m }
        guard let w = fits.contains(fw) ? fw : fits.count == 1 ? fits.first : nil else { return tty(f) }
        let tab = tabs(w)[idx.n - 1], panes = ps.filter { $0.tab_id == tab }
        return (panes.first(where: { $0.is_active == true }) ?? panes.first).flatMap(tty)
    }

    func json(_ args: [String]) -> String? { runner.run(cli, ["cli", "--no-auto-start"] + args + ["--format", "json"], timeout: 1.0) }

    /// The tty of the tab the GUI `pid` shows in the window titled `title` (`shownTTY`); nil when the CLI fails or the
    /// pane is unknown.
    public func focusedTTY(pid: Int32, title: String?) -> String? {
        guard let id = json(["list-clients"]).flatMap({ Self.focusedPane(clients: $0, pid: pid) }) else { return nil }
        return json(["list"]).flatMap { Self.shownTTY(list: $0, focused: id, title: title) }
    }
}
