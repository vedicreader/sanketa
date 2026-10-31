import Foundation
import Testing
@testable import SanketaCore

/// Kaku's `[n/m]` counts the tabs of the focused window, but a second window adds ttys: then only Kaku itself
/// knows the focused pane. The fixtures are `kaku cli list-clients` / `list --format json` from a running Kaku with
/// two windows (window 1: tabs on ttys010 and ttys002; window 0: ttys009), with names and paths replaced.
@Suite struct KakuQueryTests {
    static let cli = "/Applications/Kaku.app/Contents/MacOS/kaku"
    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/kaku/\(name).json"), encoding: .utf8)
    }

    /// Answers the CLI's read-only commands from the fixtures and records each call.
    final class FakeKaku: CommandRunning, @unchecked Sendable {
        var out: [String: String?]
        var calls: [[String]] = []
        init(_ out: [String: String?]) { self.out = out }
        func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
            calls.append([path] + args)
            return out[args.joined(separator: " ")] ?? nil
        }
    }

    static func recorded() throws -> FakeKaku {
        FakeKaku(["cli --no-auto-start list-clients --format json": try fixture("list-clients"),
                  "cli --no-auto-start list --format json": try fixture("list")])
    }

    /// The live tree: fish on 3 ttys under Kaku; on ttys010, fish runs ramabana's tmux client on a private server.
    static let snapshot = ProcessSnapshot([
        proc(28331, 1, "kaku-gui"),
        proc(28361, 28331, "fish", tty: "ttys009", fg: false, start: 5, argv: ["-fish"]),
        proc(28363, 28331, "fish", tty: "ttys010", fg: false, start: 10, argv: ["-fish"]),
        proc(17635, 28331, "fish", tty: "ttys002", start: 30, argv: ["-fish"]),
        proc(84687, 28363, "tmux", tty: "ttys010", start: 40,
             argv: ["tmux", "-L", "ramabana-6a36be8b", "new", "-A", "-s", "ramabana", "/Users/user/.local/bin/ramabana"]),
        proc(84690, 1, "tmux", start: 40, argv: ["tmux", "-L", "ramabana-6a36be8b", "new", "-A", "-s", "ramabana", "/Users/user/.local/bin/ramabana"]),
        proc(84700, 84690, "bash", tty: "ttys000", start: 41, argv: ["sh", "/Users/user/.local/bin/ramabana", "--pane"]),
    ])
    static let title = "[1/2] project"

    func resolver() throws -> LayerResolver {
        let ramabana = try PackLibrary.decode(Data("id = \"ramabana\"\nname = \"ramabana\"\nmatch = [\"bin/ramabana\"]\n".utf8))
        // only ramabana's private server knows the client on ttys010
        let tmux = FakeTmux(list: [TmuxClient(clientTTY: "ttys010", paneTTY: "ttys000", paneCommand: "bash")],
                            server: ["-L", "ramabana-6a36be8b"])
        return LayerResolver(library: lib(["fish", "tmux"], extra: [ramabana]), tmux: tmux, remote: nil)
    }

    @Test func parsesTheRealOutput() throws {
        #expect(KakuQuery.focusedPane(clients: try Self.fixture("list-clients"), pid: 28331) == 2)
        #expect(KakuQuery.shownTTY(list: try Self.fixture("list"), focused: 4, title: nil) == "ttys002")
        #expect(KakuQuery.focusedPane(clients: "not json", pid: 28331) == nil)
        #expect(KakuQuery.shownTTY(list: "", focused: 4, title: nil) == nil)
    }

    /// `sh -c … ramabana …/bin/ramabana`: the shell runs ramabana, so its layer is the program ramabana.
    @Test func shellRunningAToolIsThatTool() throws {
        let r = try resolver()
        let l = r.layer("bash", argv: ["sh", "-c", "exec python3 \"$1\"", "ramabana", "/Users/user/.local/bin/ramabana"])
        #expect(l.kind == .program && l.name == "ramabana" && l.packID == "ramabana")
        let plain = r.layer("fish", argv: ["-fish"])          // a shell with its own pack stays a shell
        #expect(plain.kind == .shell && plain.name == "fish" && plain.packID == "fish")
    }

    @Test func twoWindowsPickTheFocusedTTY() throws {
        let fake = try Self.recorded()
        let focused = KakuQuery(runner: fake, cli: Self.cli).focusedTTY(pid: 28331, title: Self.title)
        #expect(focused == "ttys010")
        // only the two read-only list commands, never one that changes Kaku
        #expect(fake.calls.map { Array($0.dropFirst(3)) } == [["list-clients", "--format", "json"], ["list", "--format", "json"]])
        #expect(fake.calls.allSatisfy { $0.prefix(3) == [Self.cli, "cli", "--no-auto-start"] })

        let r = try resolver()
        #expect(r.chooseTTY(Self.snapshot, terminalPID: 28331, title: Self.title) == nil, "[1/2] with 3 ttys: the title can't tell")
        #expect(r.chooseTTY(Self.snapshot, terminalPID: 28331, title: Self.title, focused: focused) == "ttys010")
        let ls = r.resolve(Self.snapshot, terminal: TerminalContext(pid: 28331, bundleID: "fun.tw93.kaku", appName: "Kaku",
                                                                   windowTitle: Self.title, focusedTTY: focused))
        // the pane's ramabana layer; the client's tmux layer has the same pack and shows once
        #expect(ls.map(\.name) == ["ramabana", "fish", "Kaku"])
        #expect(ls.first?.kind == .program)
        #expect(ls.map(\.packID) == ["ramabana", "fish", "app:fun.tw93.kaku"])
    }

    @Test func failedCLIFallsBackToTheTitle() throws {
        for fake in [FakeKaku([:]), FakeKaku(["cli --no-auto-start list-clients --format json": try Self.fixture("list-clients")])] {
            #expect(KakuQuery(runner: fake, cli: Self.cli).focusedTTY(pid: 28331, title: Self.title) == nil)
        }
        let r = try resolver()
        // one window, 2 tabs: the `[n/m]` heuristics still work when the CLI gives nothing
        let one = ProcessSnapshot(Self.snapshot.procs.filter { $0.tty != "ttys009" })
        #expect(r.chooseTTY(one, terminalPID: 28331, title: "[1/2] project", focused: nil) == "ttys010")
        #expect(r.chooseTTY(one, terminalPID: 28331, title: "[2/2] project", focused: nil) == "ttys002")
        // a focused tty that is not one of Kaku's (a stale answer) is ignored
        #expect(r.chooseTTY(one, terminalPID: 28331, title: "[2/2] project", focused: "ttys099") == "ttys002")
    }

    /// Another program's `kaku cli` command can move Kaku's focused pane to a tab that is not shown. The fixtures:
    /// window 1 shows tab 2 of 4 (ttys001), but Kaku names pane 91 (tab 3, ttys010). The focused pane picks the window
    /// and the title's `[n/m]` picks the tab.
    @Test func theTitlePicksTheTabOfTheFocusedWindow() throws {
        let fake = FakeKaku(["cli --no-auto-start list-clients --format json": try Self.fixture("list-clients-tabs"),
                             "cli --no-auto-start list --format json": try Self.fixture("list-tabs")])
        let kaku = KakuQuery(runner: fake, cli: Self.cli)
        #expect(kaku.focusedTTY(pid: 28331, title: "[2/4] project·tmux") == "ttys001")
        #expect(kaku.focusedTTY(pid: 28331, title: "[4/4] project") == "ttys005")
        // the focused window has 4 tabs; the only window with 1 tab is the one shown
        #expect(kaku.focusedTTY(pid: 28331, title: "[1/1] project") == "ttys021")
        // no prefix, or one that fits no window: Kaku's own answer
        #expect(kaku.focusedTTY(pid: 28331, title: nil) == "ttys010")
        #expect(kaku.focusedTTY(pid: 28331, title: "[2/3] project") == "ttys010")
    }
}
