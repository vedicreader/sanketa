import Foundation
import Testing
@testable import SanketaCore

/// Answers `list-clients` from a table keyed by the server; records each command. It runs no tmux.
private final class ResumeTmux: CommandRunning, @unchecked Sendable {
    var clients: [[String]: String] = [:]
    var calls: [[String]] = []
    func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        calls.append([path] + args)
        guard let i = args.firstIndex(where: { ["list-clients", "new-window"].contains($0) }) else { return nil }
        let server = Array(args[..<i])
        return args[i] == "list-clients" ? clients[server] : (clients[server] != nil ? "" : nil)
    }
}

@Suite struct SessionResumeTests {
    @Test func opensAWindowInTheSessionUsedLast() {
        let t = ResumeTmux()
        t.clients[["-L", "work"]] = "1700000000\t$2\n1700000500\t$5\n"
        let r = SessionResume(runner: t, servers: [("/bin/tmux", []), ("/bin/tmux", ["-L", "work"])], ramabana: "/u/bin/ramabana")
        #expect(r.inTmux("2026-10-21-ab12"))
        #expect(t.calls.last == ["/bin/tmux", "-L", "work", "new-window", "-t", "$5:", "-n", "resume", "'/u/bin/ramabana' --resume 2026-10-21-ab12"])
    }

    @Test func noAttachedClientMeansNoTmux() {
        let t = ResumeTmux()
        let r = SessionResume(runner: t, servers: [("/bin/tmux", [])], ramabana: nil)
        #expect(!r.inTmux("abc"))
        #expect(r.script("abc") == "#!/bin/zsh -l\nclear\nexec ramabana --resume abc\n")
    }

    @Test func anUnsafeIdRunsNothing() {
        let t = ResumeTmux()
        t.clients[[]] = "1\t$1\n"
        let r = SessionResume(runner: t, servers: [("/bin/tmux", [])], ramabana: nil)
        for id in ["", "a;rm -rf ~", "$(x)", "a b", "a'b"] {
            #expect(!r.inTmux(id) && r.script(id) == nil, "\(id)")
        }
        #expect(t.calls.isEmpty)
    }

    @Test func serversFromTheClients() {
        let s = SessionResume.servers(clients: [(path: "/opt/tmux", argv: ["tmux", "-L", "work", "attach"]), (path: nil, argv: ["tmux"])],
                                      fallback: [])
        #expect(s.map(\.tmux) == ["/opt/tmux", "/opt/tmux"] && s.map(\.server) == [["-L", "work"], []])
        #expect(SessionResume.servers(clients: [], fallback: ["/nonexistent/tmux"]).isEmpty)
    }

    @Test func lastSession() {
        #expect(SessionResume.lastSession("5\t$1\n9\t$3\n7\t$2") == "$3")
        #expect(SessionResume.lastSession("") == nil && SessionResume.lastSession("x\ty") == nil)
    }

    @Test func abhyasaConfig() {
        var a = AbhyasaConfig()
        #expect(!a.enabled && a.base == nil, "off by default: Sanketa works alone")
        a.enabled = true
        #expect(a.base == URL(string: "http://127.0.0.1:5077"))
        a.url = "https://example.com"
        #expect(a.base == nil, "only on this Mac")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-abhyasa-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("config.toml")
        try? "[abhyasa]\nenabled = true\nurl = \"http://localhost:7000\"\n[vault]\nmcp = false\nmcp_url = \"http://127.0.0.1:8000/mcp\"\nmcp_timeout_seconds = 2\n"
            .write(to: f, atomically: true, encoding: .utf8)
        let c = Config.load(f).config
        #expect(c.abhyasa.enabled && c.abhyasa.url == "http://localhost:7000")
        #expect(!c.vault.mcp && c.vault.mcpURL == "http://127.0.0.1:8000/mcp" && c.vault.mcpTimeoutSeconds == 2)
    }

    @Test func mcpCommand() {
        var v = VaultConfig()
        #expect(v.resolvedCommand { $0 == "/opt/homebrew/bin/vishalakshi-mcp" } == "/opt/homebrew/bin/vishalakshi-mcp")
        #expect(v.resolvedCommand { _ in false } == nil)
        v.mcpCommand = "~/x/vishalakshi-mcp"
        #expect(v.resolvedCommand { _ in true } == NSHomeDirectory() + "/x/vishalakshi-mcp")
    }
}
