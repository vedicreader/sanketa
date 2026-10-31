import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

@Suite struct TmuxQueryTests {
    func sock(_ n: String) -> String { "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-\(n)" }

    @Test func tmuxQueryLiveKeysFromRealServer() throws {
        let s = sock("k"), r = ProcessRunner()
        defer { stopTmux(s, timeout: 10.0) }
        _ = try #require(r.run(tmuxBin, ["-L", s, "-f", "/dev/null", "new", "-d", "-s", "t"], timeout: 3.0))
        let q = TmuxQuery(runner: r, socket: s)
        let live = q.liveKeys(tmux: tmuxBin)
        #expect(live.prefix == "C-b")
        #expect(live.keys.contains { $0.keys == "prefix %" && $0.command == "split-window -h" })
        _ = try #require(r.run(tmuxBin, ["-L", s, "bind-key", "|", "split-window", "-h"], timeout: 2.0))
        let after = q.liveKeys(tmux: tmuxBin)
        #expect(after.keys.contains { $0.keys == "prefix |" && $0.command == "split-window -h" })
    }

    /// Every key of the bundled tmux pack merged with a live server's bindings renders without tmux notation.
    @Test func keyNotationCoversLiveTmuxKeys() throws {
        let s = sock("n"), r = ProcessRunner()
        defer { stopTmux(s, timeout: 10.0) }
        _ = try #require(r.run(tmuxBin, ["-L", s, "-f", "/dev/null", "new", "-d", "-s", "t"], timeout: 3.0))
        let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
        let bundled = try #require(PackLibrary.load(bundled: packs, user: nil).packs["tmux"])
        let live = TmuxQuery(runner: r, socket: s).liveKeys(tmux: tmuxBin)
        let merged = Tmux.mergeLive(bundled, live: live.keys)
        try #require(merged.keys.count > 50 && live.prefix == "C-b")
        let shown = merged.keys.map { KeyNotation.display($0.keys, prefix: live.prefix) }
        let bad = shown.filter { $0.contains("C-") || $0.contains("M-") || $0.contains("prefix") }
        #expect(bad.isEmpty, "\(bad)")
        #expect(shown.contains("⌃B  %"))
    }

    @Test func tmuxQueryClientsEmptyWhenNoneAttached() throws {
        let s = sock("c"), r = ProcessRunner()
        defer { stopTmux(s, timeout: 10.0) }
        _ = try #require(r.run(tmuxBin, ["-L", s, "-f", "/dev/null", "new", "-d", "-s", "t"], timeout: 3.0))
        #expect(TmuxQuery(runner: r, socket: s).clients(tmux: tmuxBin).isEmpty)
    }

    @Test func tmuxQueryDeadServerReturnsEmpty() {
        let q = TmuxQuery(runner: ProcessRunner(), socket: sock("dead"))
        let t0 = Date()
        #expect(q.clients(tmux: tmuxBin).isEmpty)
        let live = q.liveKeys(tmux: tmuxBin)
        #expect(live.prefix == nil && live.keys.isEmpty)
        #expect(Date().timeIntervalSince(t0) < 2.0)
    }
}
