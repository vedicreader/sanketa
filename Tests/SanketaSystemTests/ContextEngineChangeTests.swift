import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// The engine's own wiring with stand-ins for the outside world: Kaku's CLI and `tmux list-clients` run only when
/// what they answer can have changed, and the menu read's retry logic.
@Suite struct ContextEngineChangeTests {
    static let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
    static let kaku = "/Applications/Kaku.app/Contents/MacOS/kaku"

    /// Answers Kaku's CLI (the real JSON shape) and ramabana's tmux server; records every call.
    final class Runner: CommandRunning, @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var focusedPane = 2
        func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
            lock.withLock { calls.append([path] + args) }
            if path == ContextEngineChangeTests.kaku, args.contains("list-clients") {
                return #"[{"pid": 28331, "workspace": "default", "focused_pane_id": \#(focusedPane)}]"#
            }
            if path == ContextEngineChangeTests.kaku, args.contains("list") {
                return #"[{"window_id": 1, "pane_id": 2, "tty_name": "/dev/ttys010"}, {"window_id": 1, "pane_id": 4, "tty_name": "/dev/ttys002"}, {"window_id": 0, "pane_id": 1, "tty_name": "/dev/ttys009"}]"#
            }
            if args.prefix(3) == ["-L", "ramabana-6a36be8b", "list-clients"] { return "/dev/ttys010\t/dev/ttys000\tbash\n" }
            return nil
        }
        func count(_ word: String) -> Int { lock.withLock { calls.filter { $0.contains(word) }.count } }
    }

    static func p(_ pid: Int32, _ ppid: Int32, _ name: String, tty: String? = nil, fg: Bool = true, start: Double = 0,
                  argv: [String]? = nil) -> ProcInfo {
        ProcInfo(pid: pid, ppid: ppid, pgid: pid, tty: tty, tpgid: fg ? pid : 0, name: name,
                 argv: argv ?? [name], start: start, path: "/opt/homebrew/bin/\(name)")
    }

    /// Kaku with fish on 3 ttys (2 windows); on ttys010 fish runs ramabana's tmux client on a private server.
    static func tree(extra: [ProcInfo] = []) -> ProcessSnapshot {
        let rb = ["tmux", "-L", "ramabana-6a36be8b", "new", "-A", "-s", "ramabana", "/Users/user/.local/bin/ramabana"]
        return ProcessSnapshot([
            p(28331, 1, "kaku-gui"),
            p(28361, 28331, "fish", tty: "ttys009", start: 5, argv: ["-fish"]),
            p(28363, 28331, "fish", tty: "ttys010", fg: false, start: 10, argv: ["-fish"]),
            p(17635, 28331, "fish", tty: "ttys002", start: 30, argv: ["-fish"]),
            p(84687, 28363, "tmux", tty: "ttys010", start: 40, argv: rb),
            p(84690, 1, "tmux", start: 40, argv: rb),
            p(84700, 84690, "bash", tty: "ttys000", start: 41, argv: ["sh", "/Users/user/.local/bin/ramabana"]),
        ] + extra)
    }

    final class World: @unchecked Sendable {
        let lock = NSLock()
        var title: String? = "[1/2] project", window = 7, snap = ContextEngineChangeTests.tree()
        var menu: [MenuShortcut] = [MenuShortcut(path: ["Shell", "New Tab"], keys: "⌘T")], menuDelay = 0.0, menuReads = 0
    }

    func engine(_ r: Runner, _ w: World) -> ContextEngine {
        var e = ContextEngine(config: Config(), library: PackLibrary.load(bundled: Self.packs, user: nil))
        e.runner = r
        e.isTrusted = { true }
        e.snapshot = { _ in w.lock.withLock { w.snap } }
        e.focusedWindow = { _ in w.lock.withLock { (w.title, w.window) } }
        e.kakuCLI = { _ in Self.kaku }
        e.readMenu = { _ in
            let (m, d) = w.lock.withLock { w.menuReads += 1; return (w.menu, w.menuDelay) }
            Thread.sleep(forTimeInterval: d)
            return m
        }
        e.slowMenu = 0.1
        return e
    }

    func kakuCompute(_ e: ContextEngine) -> Context { e.compute(pid: 28331, bundleID: "fun.tw93.kaku", appName: "Kaku") }

    @Test func kakuCLIRunsOnlyWhenTheWindowChanges() {
        let r = Runner(), w = World(), e = engine(r, w)
        for _ in 0..<5 { #expect(kakuCompute(e).layers.map(\.name) == ["ramabana", "fish", "Kaku"]) }
        #expect(r.count("list-clients") - r.count("-L") == 1 && r.count("--no-auto-start") == 2, "one CLI pair for 5 polls")
        w.title = "[2/2] project"                     // another tab
        r.focusedPane = 4
        #expect(kakuCompute(e).layers.map(\.name) == ["fish", "Kaku"])
        #expect(r.count("--no-auto-start") == 4)
        _ = kakuCompute(e)
        #expect(r.count("--no-auto-start") == 4)
        w.window = 8                                  // another window with the same title
        _ = kakuCompute(e)
        #expect(r.count("--no-auto-start") == 6)
        e.resetChanges()                              // what an activation does
        _ = kakuCompute(e)
        #expect(r.count("--no-auto-start") == 8)
    }

    @Test func kakuCLIOnlyForKakuWithSeveralTTYs() {
        let r = Runner(), w = World(), e = engine(r, w)
        _ = e.compute(pid: 28331, bundleID: "com.apple.Terminal", appName: "Terminal")
        #expect(r.count("--no-auto-start") == 0, "another terminal never runs Kaku's CLI")
        w.snap = ProcessSnapshot(Self.tree().procs.filter { $0.tty != "ttys009" && $0.tty != "ttys002" })
        _ = kakuCompute(e)
        #expect(r.count("--no-auto-start") == 0, "one tty: nothing to choose")
        var noCLI = engine(r, World())
        noCLI.kakuCLI = { _ in nil }
        #expect(kakuCompute(noCLI).layers.map(\.name) == ["fish", "Kaku"], "no CLI: the title cannot tell, so only the shared login shell")
        #expect(r.count("--no-auto-start") == 0)
    }

    @Test func tmuxClientsAreReadAgainOnlyOnChange() {
        let r = Runner(), w = World(), e = engine(r, w)
        for _ in 0..<5 { _ = kakuCompute(e) }
        #expect(r.count("ramabana-6a36be8b") == 1, "one list-clients for 5 polls of an unchanged tree")
        // a program starts in front of the pane
        w.snap = Self.tree(extra: [Self.p(84800, 84700, "htop", tty: "ttys000", start: 50)].map {
            var q = $0; q.pgid = 84800; q.tpgid = 84800; return q })
        _ = kakuCompute(e)
        #expect(r.count("ramabana-6a36be8b") == 2)
        _ = kakuCompute(e)
        #expect(r.count("ramabana-6a36be8b") == 2)
        w.title = "[1/2] other"                       // new text, the same tab
        _ = kakuCompute(e)
        #expect(r.count("ramabana-6a36be8b") == 2)
        w.title = "[2/2] other"                       // another tab
        _ = kakuCompute(e)
        #expect(r.count("ramabana-6a36be8b") == 3)
        w.window = 8                                  // another window
        _ = kakuCompute(e)
        #expect(r.count("ramabana-6a36be8b") == 4)
    }

    /// A spinner or a clock in the title changes its text each second; that must not start a CLI run each poll.
    @Test func titleThatTicksDoesNotRunCommands() {
        let r = Runner(), w = World(), e = engine(r, w)
        for i in 0..<10 {
            w.lock.withLock { w.title = "[1/2] \(["⠋", "⠙", "⠹", "⠸"][i % 4]) claude \(i)s" }
            #expect(kakuCompute(e).layers.map(\.name) == ["ramabana", "fish", "Kaku"])
        }
        #expect(r.count("list-clients") - r.count("-L") == 1 && r.count("--no-auto-start") == 2, "one Kaku CLI pair for 10 polls")
        #expect(r.count("ramabana-6a36be8b") == 1, "one tmux list-clients for 10 polls")
    }

    @Test func slowMenuReadIsKeptAndReadOnceMore() {
        let r = Runner(), w = World(), e = engine(r, w)
        w.menuDelay = 0.15                            // slower than `slowMenu`: it may have hit the timeout
        let a = e.compute(pid: 4242, bundleID: "org.example.app", appName: "App")
        #expect(a.menuIncomplete && a.packs.first?.keys.count == 1, "a slow read still shows its keys")
        let b = e.compute(pid: 4242, bundleID: "org.example.app", appName: "App")
        #expect(w.menuReads == 2 && !b.menuIncomplete, "the retry reads again; a second slow read is final")
        _ = e.compute(pid: 4242, bundleID: "org.example.app", appName: "App")
        #expect(w.menuReads == 2, "then the cache answers")

        w.menuDelay = 0
        w.menu = []                                   // an app with no menu bar yet
        let c = e.compute(pid: 4343, bundleID: "org.example.new", appName: "New")
        #expect(c.menuIncomplete && c.packs.first?.keys.isEmpty == true)
        w.menu = [MenuShortcut(path: ["File", "New"], keys: "⌘N")]
        let d = e.compute(pid: 4343, bundleID: "org.example.new", appName: "New")
        #expect(!d.menuIncomplete && d.packs.first?.keys.count == 1 && w.menuReads == 4)
        _ = e.compute(pid: 4343, bundleID: "org.example.new", appName: "New")
        #expect(w.menuReads == 4)
    }
}
