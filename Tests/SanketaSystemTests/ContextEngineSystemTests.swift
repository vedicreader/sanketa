import AppKit
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// Real bundled packs from the repo, a private outer tmux server standing in for the terminal, a private inner server running htop.
@Suite(.serialized) struct ContextEngineSystemTests {
    let r = ProcessRunner()
    let outer = "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-ce-outer"
    let inner = "sanketa-test-\(ProcessInfo.processInfo.processIdentifier)-ce-inner"
    static let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")

    func tmux(_ sock: String, _ args: [String]) -> String? { r.run(tmuxBin, ["-L", sock] + args, timeout: 3.0) }

    func waitFor(_ ok: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        while !ok() && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
    }

    @Test func contextEngineRealTerminalStandIn() throws {
        defer {
            _ = tmux(inner, ["kill-server"])
            _ = tmux(outer, ["kill-server"])
        }
        let lib = PackLibrary.load(bundled: Self.packs, user: nil)
        try #require(lib.errors.isEmpty && lib.packs["tmux"] != nil)
        _ = try #require(tmux(outer, ["-f", "/dev/null", "new", "-d", "-s", "outer", "-x", "200", "-y", "50",
                                      "/opt/homebrew/bin/fish", "--no-config"]))
        let server = try #require(tmux(outer, ["display", "-p", "-t", "outer", "#{pid}"])
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        _ = try #require(tmux(outer, ["send-keys", "-t", "outer",
            "set -gx SHELL /opt/homebrew/bin/fish; /opt/homebrew/bin/tmux -L \(inner) -f /dev/null new -s inner", "Enter"]))
        waitFor { tmux(inner, ["has-session", "-t", "inner"]) != nil }
        // a binding only the live server has proves the merge reads it
        _ = try #require(tmux(inner, ["bind-key", "|", "split-window", "-h"]))
        _ = try #require(tmux(inner, ["send-keys", "-t", "inner", "/opt/homebrew/bin/htop", "Enter"]))
        let pane = try #require(tmux(inner, ["display", "-p", "-t", "inner", "#{pane_tty}"]))
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
        // other suites may run htop concurrently; wait for ours, on the inner pane's tty
        waitFor { SysctlProcesses.snapshot().foreground(tty: pane)?.name == "htop" }

        var config = Config()
        config.terminals = ["test.terminal"]
        let c = ContextEngine(config: config, library: lib, tmuxSocket: inner)
            .compute(pid: server, bundleID: "test.terminal", appName: "TestTerm")
        #expect(c.layers.map(\.name) == ["htop", "fish", "tmux", "TestTerm"])
        #expect(c.packs.map(\.id) == ["htop", "fish", "tmux", "app:test.terminal"])
        let t = try #require(c.packs.first { $0.id == "tmux" })
        #expect(t.keys.contains { $0.keys.hasPrefix("prefix ") })
        #expect(t.keys.contains { $0.keys == "prefix |" && $0.command == "split-window -h" })
        #expect(t.keys.contains { $0.action == "Split pane left/right" })
        #expect(t.prefix == "C-b")
    }

    @Test func contextEngineNonTerminalApp() throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let lib = PackLibrary.load(bundled: Self.packs, user: nil)
        let c = ContextEngine(config: Config(), library: lib)
            .compute(pid: finder.processIdentifier, bundleID: "com.apple.finder", appName: "Finder")
        #expect(c.layers == [Layer(kind: .app, name: "Finder", packID: "app:com.apple.finder")])
        let p = try #require(c.packs.first)
        #expect(c.packs.count == 1 && p.id == "app:com.apple.finder")
        if AXReader.isTrusted {
            #expect(c.axTrusted)
            #expect(p.keys.count >= 5)
            #expect(p.keys.contains { $0.keys == "⌘N" })
        } else {
            #expect(!c.axTrusted)
            #expect(p.keys.isEmpty)
        }
    }
}

@Suite struct TTLCacheTests {
    @Test func emptyMenuReadIsNotCached() {
        let c = TTLCache<pid_t, [MenuShortcut]>(ttl: 60)
        let item = MenuShortcut(path: ["File", "New"], keys: "⌘N")
        var loads = 0
        func read(_ v: [MenuShortcut]) -> [MenuShortcut] { c.get(1, keep: { !$0.isEmpty }) { loads += 1; return v } }
        #expect(read([]).isEmpty)
        #expect(read([item]) == [item])
        #expect(read([]) == [item])
        #expect(loads == 2)
    }

    @Test func entriesExpireAfterTTL() {
        let c = TTLCache<String, Int>(ttl: 0.2)
        #expect(c.get("k") { 1 } == 1)
        #expect(c.get("k") { 2 } == 1)
        Thread.sleep(forTimeInterval: 0.3)
        #expect(c.get("k") { 3 } == 3)
    }
}
