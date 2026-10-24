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
    struct Pane: Decodable { var pane_id: Int; var tty_name: String? }

    /// The focused pane id of the GUI `pid`, from `list-clients --format json`.
    public static func focusedPane(clients json: String, pid: Int32) -> Int? {
        guard let cs = try? JSONDecoder().decode([Client].self, from: Data(json.utf8)) else { return nil }
        return (cs.first { $0.pid == pid } ?? (cs.count == 1 ? cs[0] : nil))?.focused_pane_id
    }

    /// Pane id to tty (`ttys010`), from `list --format json`.
    public static func paneTTYs(list json: String) -> [Int: String] {
        guard let ps = try? JSONDecoder().decode([Pane].self, from: Data(json.utf8)) else { return [:] }
        return Dictionary(ps.compactMap { p in p.tty_name.map { (p.pane_id, $0.replacingOccurrences(of: "/dev/", with: "")) } }) { a, _ in a }
    }

    func json(_ args: [String]) -> String? { runner.run(cli, ["cli", "--no-auto-start"] + args + ["--format", "json"], timeout: 1.0) }

    /// The tty of the pane the GUI `pid` has in focus; nil when the CLI fails or the pane is unknown.
    public func focusedTTY(pid: Int32) -> String? {
        guard let id = json(["list-clients"]).flatMap({ Self.focusedPane(clients: $0, pid: pid) }) else { return nil }
        return json(["list"]).map(Self.paneTTYs)?[id]
    }
}
