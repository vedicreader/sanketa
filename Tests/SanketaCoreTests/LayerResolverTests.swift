import Foundation
import Testing
@testable import SanketaCore

struct FakeTmux: TmuxQuerying {
    var list: [TmuxClient] = []
    func clients(tmux: String) -> [TmuxClient] { list }
    func liveKeys(tmux: String) -> (prefix: String?, keys: [KeyEntry]) { (nil, []) }
}

struct FakeRemote: RemoteQuerying {
    var cmd: String?
    func paneCommand(sshArgv: [String]) -> String? { cmd }
}

func proc(_ pid: Int32, _ ppid: Int32, _ name: String, tty: String? = nil, fg: Bool = true, start: Double = 0,
          argv: [String]? = nil) -> ProcInfo {
    ProcInfo(pid: pid, ppid: ppid, pgid: pid, tty: tty, tpgid: fg ? pid : 0, name: name,
             argv: argv ?? [name], start: start, path: "/usr/bin/\(name)")
}

let conterm = TerminalContext(pid: 100, bundleID: "com.example.Conterm", appName: "Conterm", windowTitle: nil)

func lib(_ ids: [String], extra: [Pack] = []) -> PackLibrary {
    PackLibrary(packs: Dictionary(uniqueKeysWithValues: (ids.map { Pack(id: $0, name: $0, processes: [$0]) } + extra).map { ($0.id, $0) }))
}

func titled(_ t: String?) -> TerminalContext {
    var c = conterm; c.windowTitle = t; return c
}

@Suite struct LayerResolverTests {
    let tmuxClient = TmuxClient(clientTTY: "ttys001", paneTTY: "ttys005", paneCommand: "htop")

    @Test func resolveTmuxHtop() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        let r = LayerResolver(library: lib(["fish", "tmux", "htop"]), tmux: FakeTmux(list: [tmuxClient]), remote: nil)
        let ls = r.resolve(s, terminal: conterm)
        #expect(ls.map(\.name) == ["htop", "fish", "tmux", "Conterm"])
        #expect(ls.map(\.kind) == [.program, .shell, .multiplexer, .terminal])
        #expect(ls.map(\.packID) == ["htop", "fish", "tmux", "app:com.example.Conterm"])
        #expect(ls.map(\.id) == ["local/htop", "local/fish", "local/tmux", "local/app:com.example.Conterm"])
    }

    @Test func resolveTmuxWithNoClientsShowsBareTmux() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        let r = LayerResolver(library: lib(["fish", "tmux"]), tmux: FakeTmux(), remote: nil)
        #expect(r.resolve(s, terminal: conterm).map(\.name) == ["tmux", "fish", "Conterm"])
    }

    @Test func resolveTmuxClientOnOtherTTYIsIgnored() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        let other = TmuxClient(clientTTY: "ttys009", paneTTY: "ttys005", paneCommand: "htop")
        let r = LayerResolver(library: lib([]), tmux: FakeTmux(list: [other]), remote: nil)
        #expect(r.resolve(s, terminal: conterm).map(\.name) == ["tmux", "fish", "Conterm"])
    }

    @Test func resolveRamabanaByArgv() {
        let s = ProcessSnapshot([
            proc(100, 1, "Conterm"),
            proc(200, 100, "fish", tty: "ttys001", fg: false),
            ProcInfo(pid: 300, ppid: 200, pgid: 300, tty: "ttys001", tpgid: 300, name: "python3",
                     argv: ["python3", "/Users/x/.local/bin/ramabana"], start: 1, path: "/usr/bin/python3"),
        ])
        let rama = Pack(id: "ramabana", name: "ramabana", match: ["ramabana"])
        let r = LayerResolver(library: lib(["fish", "python3"], extra: [rama]), tmux: FakeTmux(), remote: nil)
        let ls = r.resolve(s, terminal: conterm)
        #expect(ls.first?.packID == "ramabana" && ls.first?.name == "ramabana" && ls.first?.kind == .program)
        #expect(ls.map(\.packID) == ["ramabana", "fish", "app:com.example.Conterm"])
    }

    func sshSnapshot(_ argv: [String]) -> ProcessSnapshot {
        ProcessSnapshot([
            proc(100, 1, "Conterm"),
            proc(150, 100, "login", tty: "ttys001", fg: false),
            proc(200, 150, "fish", tty: "ttys001", fg: false),
            proc(300, 200, "ssh", tty: "ttys001", argv: argv),
        ])
    }

    @Test func resolveRemoteTag() {
        let r = LayerResolver(library: lib(["fish", "tmux", "htop"]), tmux: FakeTmux(), remote: FakeRemote(cmd: "vim"))
        let ls = r.resolve(sshSnapshot(["ssh", "gpubox"]), terminal: titled("⟦sanketa host=gpubox layers=fish,tmux,htop⟧ htop"))
        #expect(ls.map(\.name) == ["htop", "tmux", "fish", "gpubox", "fish", "Conterm"])
        #expect(ls.map(\.host) == ["gpubox", "gpubox", "gpubox", "gpubox", nil, nil])
        #expect(ls.map(\.kind) == [.program, .multiplexer, .shell, .remote, .shell, .terminal])
        #expect(ls.map(\.packID) == ["htop", "tmux", "fish", nil, "fish", "app:com.example.Conterm"])
        #expect(ls[0].id == "gpubox/htop" && ls[4].id == "local/fish")
    }

    @Test func resolveSshWithoutTag() {
        let r = LayerResolver(library: lib(["fish"]), tmux: FakeTmux(), remote: nil)
        let ls = r.resolve(sshSnapshot(["ssh", "-p", "22", "gpubox"]), terminal: titled("gpubox: ~"))
        #expect(ls.map(\.name) == ["gpubox", "fish", "Conterm"])
        #expect(ls[0].kind == .remote && ls[0].host == "gpubox")
    }

    @Test func resolveSshUsesRemotePaneCommand() {
        let r = LayerResolver(library: lib(["fish", "htop"]), tmux: FakeTmux(), remote: FakeRemote(cmd: "htop"))
        let ls = r.resolve(sshSnapshot(["ssh", "gpubox"]), terminal: conterm)
        #expect(ls.map(\.name) == ["htop", "gpubox", "fish", "Conterm"])
        #expect(ls[0].host == "gpubox" && ls[0].packID == "htop" && ls[0].kind == .program && ls[1].kind == .remote)
    }

    @Test func resolveSshInsideTmuxPaneIsRemote() {
        let s = ProcessSnapshot([
            proc(100, 1, "Conterm"),
            proc(200, 100, "fish", tty: "ttys001", fg: false),
            proc(300, 200, "tmux", tty: "ttys001"),
            proc(400, 1, "tmux"),
            proc(500, 400, "fish", tty: "ttys005", fg: false),
            proc(600, 500, "ssh", tty: "ttys005", argv: ["ssh", "gpubox"]),
        ])
        let r = LayerResolver(library: lib(["fish", "tmux"]), tmux: FakeTmux(list: [tmuxClient]), remote: nil)
        let ls = r.resolve(s, terminal: conterm)
        #expect(ls.map(\.name) == ["gpubox", "fish", "tmux", "Conterm"])
        #expect(ls[0].kind == .remote && ls[0].host == "gpubox")
    }

    func twoTTYs() -> ProcessSnapshot {
        ProcessSnapshot([
            proc(100, 1, "Conterm"),
            proc(200, 100, "fish", tty: "ttys001", fg: false),
            proc(201, 200, "htop", tty: "ttys001", start: 10),
            proc(300, 100, "fish", tty: "ttys002", fg: false),
            proc(301, 300, "vim", tty: "ttys002", start: 20),
        ])
    }

    @Test func chooseTTYPrefersTitleMatch() {
        let r = LayerResolver(library: lib([]), tmux: FakeTmux(), remote: nil)
        #expect(r.chooseTTY(twoTTYs(), terminalPID: 100, title: "htop") == "ttys001")
        #expect(r.chooseTTY(twoTTYs(), terminalPID: 100, title: "⟦sanketa host=vim layers=vim⟧ htop") == "ttys001")
        #expect(r.chooseTTY(twoTTYs(), terminalPID: 100, title: "nothing") == nil)
        #expect(r.chooseTTY(twoTTYs(), terminalPID: 100, title: "htop vim") == nil)
    }

    @Test func foregroundProgramWithoutPackIsALayer() {
        func top(_ name: String, _ argv: [String]) -> Layer? {
            let s = ProcessSnapshot([
                proc(100, 1, "Conterm"),
                proc(200, 100, "fish", tty: "ttys005", fg: false),
                ProcInfo(pid: 300, ppid: 200, pgid: 300, tty: "ttys005", tpgid: 300, name: name, argv: argv, start: 1, path: nil),
            ])
            let ls = LayerResolver(library: lib(["fish"]), tmux: FakeTmux(), remote: nil).resolve(s, terminal: conterm)
            #expect(ls.count == 3 && ls[1].name == "fish" && ls[2].name == "Conterm")
            return ls.first
        }
        // Claude Code: executable ~/.local/share/claude/versions/2.1.310, argv ["claude"]
        let c = top("2.1.310", ["claude"])
        #expect(c?.name == "claude" && c?.kind == .program && c?.packID == nil)
        #expect(top("node", ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"])?.name == "claude-code")
        #expect(top("node", ["node", "--no-warnings", "/opt/bin/claude"])?.name == "claude")
        #expect(top("python3", ["python3", "/Users/x/.local/bin/ramabana", "gen"])?.name == "ramabana")
        #expect(top("python3.12", ["/usr/bin/python3.12"])?.name == "python3.12")
        #expect(top("vim", ["/usr/bin/vim", "notes.md"])?.name == "vim")
    }

    @Test func chooseTTYDoesNotGuess() {
        let r = LayerResolver(library: lib([]), tmux: FakeTmux(), remote: nil)
        #expect(r.chooseTTY(twoTTYs(), terminalPID: 100, title: nil) == nil)
        #expect(r.chooseTTY(twoTTYs(), terminalPID: 999, title: nil) == nil)
    }

    /// The user's Conterm: two tabs run a tmux client, the one they're on runs plain fish; the title is just "Conterm".
    @Test func ambiguousTabsShowOnlySharedShell() {
        let s = ProcessSnapshot([
            proc(100, 1, "Conterm"),
            proc(200, 100, "login", tty: "ttys000", fg: false),
            proc(201, 200, "fish", tty: "ttys000", fg: false),
            proc(202, 201, "tmux", tty: "ttys000", start: 10),
            proc(300, 100, "fish", tty: "ttys001", fg: false),
            proc(301, 300, "tmux", tty: "ttys001", start: 20),
            proc(500, 100, "fish", tty: "ttys005", start: 5),
            proc(400, 1, "tmux"),
            proc(410, 400, "fish", tty: "ttys009", fg: false),
            proc(411, 410, "htop", tty: "ttys009"),
        ])
        let client = TmuxClient(clientTTY: "ttys001", paneTTY: "ttys009", paneCommand: "htop")
        let r = LayerResolver(library: lib(["fish", "tmux", "htop"]), tmux: FakeTmux(list: [client]), remote: nil)
        for t in [nil, "Conterm"] as [String?] {
            let ls = r.resolve(s, terminal: titled(t))
            #expect(ls.map(\.name) == ["fish", "Conterm"])
            #expect(ls.map(\.kind) == [.shell, .terminal])
        }
        // different shells per tab: terminal layer only
        var mixed = s.procs
        mixed[mixed.firstIndex { $0.pid == 500 }!].name = "zsh"
        #expect(r.resolve(ProcessSnapshot(mixed), terminal: conterm).map(\.name) == ["Conterm"])
        // a unique title match still resolves fully
        #expect(r.resolve(s, terminal: titled("fish ~/c/p/orgs")).map(\.name) == ["fish", "Conterm"])
    }

    @Test func resolveWithoutTitleStillResolves() throws {
        let s = try loadSnapshot("conterm_tmux_htop")
        let r = LayerResolver(library: lib([]), tmux: FakeTmux(list: [tmuxClient]), remote: nil)
        let ls = r.resolve(s, terminal: conterm)
        #expect(ls.map(\.name) == ["htop", "fish", "tmux", "Conterm"])
        #expect(ls.map(\.packID) == [nil, nil, nil, "app:com.example.Conterm"])
    }

    @Test func resolveWithNoTTYIsJustTerminal() {
        let r = LayerResolver(library: lib([]), tmux: FakeTmux(), remote: nil)
        let ls = r.resolve(ProcessSnapshot([proc(100, 1, "Conterm")]), terminal: conterm)
        #expect(ls == [Layer(kind: .terminal, name: "Conterm", packID: "app:com.example.Conterm", host: nil)])
    }

    @Test func resolveAppIsOneLayer() {
        let r = LayerResolver(library: lib([]), tmux: FakeTmux(), remote: nil)
        let ls = r.resolveApp(bundleID: "com.apple.Safari", name: "Safari")
        #expect(ls.map(\.kind) == [.app] && ls[0].packID == "app:com.apple.Safari" && ls[0].name == "Safari")
    }
}
