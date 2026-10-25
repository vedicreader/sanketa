import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// The live tree of 2026-10-25 as synthetic processes. Kaku window 1 has 3 tabs: ttys010 (ramabana's tmux client), ttys002 (fish), ttys003 (claude); window 0 has ttys009.
@Suite struct KakuSwitchTests {
    static let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
    static let kaku = "/Applications/Kaku.app/Contents/MacOS/kaku"

    final class Runner: CommandRunning, @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var focusedPane = 6
        /// list-clients answer of each private tmux server, by socket name
        var tmuxClients: [String: String] = ["ramabana-6a36be8b": "/dev/ttys010\t/dev/ttys000\tbash\n"]
        func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
            lock.withLock { calls.append([path] + args) }
            if path == KakuSwitchTests.kaku, args.contains("list-clients") {
                return #"[{"pid": 28331, "focused_pane_id": \#(lock.withLock { focusedPane })}]"#
            }
            if path == KakuSwitchTests.kaku, args.contains("list") {
                return #"[{"pane_id": 2, "tty_name": "/dev/ttys010"}, {"pane_id": 4, "tty_name": "/dev/ttys002"}, {"pane_id": 6, "tty_name": "/dev/ttys003"}, {"pane_id": 1, "tty_name": "/dev/ttys009"}]"#
            }
            if args.first == "-L", args.count > 2, args[2] == "list-clients" { return lock.withLock { tmuxClients[args[1]] } }
            return nil
        }
        func count(_ w: String) -> Int { lock.withLock { calls.filter { $0.contains(w) }.count } }
    }

    static func p(_ pid: Int32, _ ppid: Int32, _ name: String, tty: String? = nil, fg: Int32? = nil, start: Double = 0,
                  argv: [String]? = nil) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, pgid: pid, tty: tty, tpgid: fg ?? pid, name: name, argv: argv ?? [name], start: start,
                 path: "/opt/homebrew/bin/\(name)")
    }
    static let rb = ["tmux", "-L", "ramabana-6a36be8b", "-f", "/Users/u/.config/ramabana/tmux.conf", "new-session", "-s", "ramabana",
                     "sh", "-c", "$@", "ramabana", "/Users/u/.local/bin/ramabana", "--vault"]

    static func tree(tty003: [ProcInfo]? = nil) -> ProcessSnapshot {
        ProcessSnapshot([
            p(28331, 1, "kaku-gui"),
            p(28361, 28331, "fish", tty: "ttys009", start: 5, argv: ["/opt/homebrew/bin/fish", "-l"]),
            p(28363, 28331, "fish", tty: "ttys010", fg: 84687, start: 10, argv: ["/opt/homebrew/bin/fish", "-l"]),
            p(84687, 28363, "tmux", tty: "ttys010", start: 40, argv: rb),
            p(84690, 1, "tmux", start: 40, argv: rb),
            p(84700, 84690, "sh", tty: "ttys000", start: 41, argv: ["sh", "-c", "$@", "ramabana", "/Users/u/.local/bin/ramabana"]),
            p(17635, 28331, "fish", tty: "ttys002", start: 30, argv: ["/opt/homebrew/bin/fish", "-l"]),
        ] + (tty003 ?? [
            p(16353, 28331, "fish", tty: "ttys003", fg: 16596, start: 50, argv: ["/opt/homebrew/bin/fish", "-l"]),
            p(16596, 16353, "claude", tty: "ttys003", start: 60, argv: ["claude", "--resume"]),
        ]))
    }

    final class World: @unchecked Sendable {
        let lock = NSLock()
        var title: String? = "[3/3] personal/orgs", window = 1668273338, snap = KakuSwitchTests.tree()
    }

    func engine(_ r: Runner, _ w: World) -> ContextEngine {
        var e = ContextEngine(config: Config(), library: PackLibrary.load(bundled: Self.packs, user: nil))
        e.runner = r
        e.isTrusted = { true }
        e.snapshot = { _ in w.lock.withLock { w.snap } }
        e.focusedWindow = { _ in w.lock.withLock { (w.title, w.window) } }
        e.kakuCLI = { _ in Self.kaku }
        e.readMenu = { _, _ in [MenuShortcut(path: ["Shell", "New Tab"], keys: "⌘T")] }
        return e
    }
    func names(_ e: ContextEngine) -> [String] { e.compute(pid: 28331, bundleID: "fun.tw93.kaku", appName: "Kaku").layers.map(\.name) }

    /// Live: the AX title shows the new tab a moment before Kaku's CLI moves `focused_pane_id`; the poll in between
    /// stores the old tab's tty under the new key, and no later poll asks again.
    @Test func tabSwitchWhileTheCLILagsShowsTheNewTabOnALaterPoll() {
        let r = Runner(), w = World(), e = engine(r, w)
        #expect(names(e) == ["claude", "fish", "Kaku"])
        w.title = "[1/3] personal/orgs"               // Cmd-1: the title is already the ramabana tab's
        _ = names(e)                                  // CLI still says pane 6 (claude)
        r.focusedPane = 2                             // Kaku's focus record catches up
        var shown: [String] = []
        for _ in 0..<5 { shown = names(e) }           // 5 more polls, nothing else changes
        #expect(shown.first == "ramabana", "stays on claude: \(shown)")
    }

    /// The same tab: claude exits and ramabana starts there (same tty, new foreground group).
    @Test func sameTabClaudeToRamabana() {
        let r = Runner(), w = World(), e = engine(r, w)
        #expect(names(e) == ["claude", "fish", "Kaku"])
        let rb2 = Self.rb.map { $0 == "ramabana-6a36be8b" ? "ramabana-9b19b87d" : $0 }
        r.tmuxClients["ramabana-9b19b87d"] = ""      // the new server has no client yet
        w.snap = Self.tree(tty003: [
            Self.p(16353, 28331, "fish", tty: "ttys003", fg: 14429, start: 50, argv: ["/opt/homebrew/bin/fish", "-l"]),
            Self.p(14429, 16353, "tmux", tty: "ttys003", start: 70, argv: rb2),
            Self.p(14432, 1, "tmux", start: 70, argv: rb2),
            Self.p(14436, 14432, "sh", tty: "ttys004", start: 71, argv: ["sh", "-c", "$@", "ramabana", "/Users/u/.local/bin/ramabana"]),
        ])
        let first = names(e)
        #expect(first.first == "tmux" && first.contains("fish"), "the server has no client yet: \(first)")
        let c = e.compute(pid: 28331, bundleID: "fun.tw93.kaku", appName: "Kaku")
        #expect(c.packs.contains { $0.id == "ramabana" }, "the ramabana keys show at once")
        r.tmuxClients["ramabana-9b19b87d"] = "/dev/ttys003\t/dev/ttys004\tsh\n"
        // the empty client list was not kept, so the next compute asks again and finds ramabana's pane
        #expect(names(e).first == "ramabana")
    }
}
