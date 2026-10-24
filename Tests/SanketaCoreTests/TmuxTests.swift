import Foundation
import Testing
@testable import SanketaCore

func tmuxFixture(_ name: String) throws -> String {
    try String(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/tmux/\(name).txt"), encoding: .utf8)
}

@Suite struct TmuxTests {
    @Test func parseClientsStripsDev() throws {
        let cs = Tmux.parseClients(try tmuxFixture("list-clients"))
        #expect(cs == [TmuxClient(clientTTY: "ttys003", paneTTY: "ttys007", paneCommand: "fish"),
                       TmuxClient(clientTTY: "ttys004", paneTTY: "ttys009", paneCommand: "htop")])
    }

    @Test func parseKeysPrefixAndRoot() throws {
        let ks = Tmux.parseKeys(try tmuxFixture("list-keys"))
        let split = try #require(ks.first { $0.keys == "prefix %" })
        #expect(split.command == "split-window -h")
        #expect(split.action == "split-window -h")
        #expect(split.group == "Live bindings")
        #expect(!ks.contains { $0.keys.contains("Mouse") || $0.keys.contains("Wheel") || $0.keys.contains("Click") })
        #expect(ks.contains { $0.keys == "prefix c" && $0.command == "new-window" })
        let root = Tmux.parseKeys("bind-key -n -T root       M-h                       select-pane -L\nbind-key    -T root       WheelUpPane               copy-mode -e")
        #expect(root == [KeyEntry(keys: "M-h", action: "select-pane -L", group: "Live bindings", command: "select-pane -L", staysOnMac: true)])
    }

    @Test func parseKeysRepeatFlagAndEscapes() throws {
        let ks = Tmux.parseKeys(##"""
        bind-key -r -T prefix       Up                        select-pane -U
        bind-key    -T prefix       \"                        split-window
        bind-key    -T prefix       \;                        last-pane
        bind-key    -T prefix       \#                        list-buffers
        bind-key    -T copy-mode    q                         send-keys -X cancel
        """##)
        #expect(ks.map(\.keys) == ["prefix Up", "prefix \"", "prefix ;", "prefix #"])
        #expect(ks[0].command == "select-pane -U")
        let real = Tmux.parseKeys(try tmuxFixture("list-keys"))
        #expect(real.contains { $0.keys == "prefix Up" && $0.command == "select-pane -U" })
        #expect(real.contains { $0.keys == "prefix \"" && $0.command == "split-window" })
        #expect(real.contains { $0.keys == "prefix ;" && $0.command == "last-pane" })
        #expect(real.contains { $0.keys == "prefix -" && $0.command == "delete-buffer" })
        let dash = Tmux.parseKeys("bind-key -T prefix - split-window -v")
        #expect(dash == [KeyEntry(keys: "prefix -", action: "split-window -v", group: "Live bindings", command: "split-window -v",
                                 staysOnMac: true)])
        #expect(real.contains { $0.keys == "prefix #" && $0.command == "list-buffers" })
    }

    @Test func mergeLiveUsesUserKeysWithBundledLabel() {
        let pack = Pack(id: "tmux", name: "tmux", keys: [
            KeyEntry(keys: "prefix %", action: "Split left/right", group: "Panes", command: "split-window -h")])
        let live = [KeyEntry(keys: "prefix |", action: "split-window -h", group: "Live bindings", command: "split-window -h")]
        let m = Tmux.mergeLive(pack, live: live)
        #expect(m.keys == [KeyEntry(keys: "prefix |", action: "Split left/right", group: "Panes", command: "split-window -h")])
    }

    @Test func mergeLiveDropsUnbound() {
        let pack = Pack(id: "tmux", name: "tmux", keys: [
            KeyEntry(keys: "prefix %", action: "Split", command: "split-window -h"),
            KeyEntry(keys: "prefix ?", action: "Help")])
        let live = [KeyEntry(keys: "prefix c", action: "new-window", group: "Live bindings", command: "new-window")]
        let m = Tmux.mergeLive(pack, live: live)
        #expect(m.keys.map(\.keys) == ["prefix ?", "prefix c"])
    }
}
