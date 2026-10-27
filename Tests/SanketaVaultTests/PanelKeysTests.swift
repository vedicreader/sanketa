import AppKit
import Testing
import SanketaCore
@testable import SanketaUI
import SanketaVault

/// The keys of the search field and the status-menu toggles. These tests make menus only: no window, no focus.
@MainActor @Suite struct PanelKeysTests {
    @Test func editMenuHasTheStandardTextKeys() {
        let edit = EditMenu.make().items.first { $0.title == "Edit" }?.submenu
        func item(_ t: String) -> NSMenuItem? { edit?.items.first { $0.title == t } }
        let want: [(String, String, String, NSEvent.ModifierFlags)] = [
            ("Undo", "undo:", "z", .command), ("Redo", "redo:", "Z", .command), ("Cut", "cut:", "x", .command),
            ("Copy", "copy:", "c", .command), ("Paste", "paste:", "v", .command), ("Select All", "selectAll:", "a", .command)]
        for (t, sel, key, mods) in want {
            #expect(item(t)?.action == Selector((sel)) && item(t)?.keyEquivalent == key && item(t)?.keyEquivalentModifierMask == mods, "\(t)")
        }
        #expect(item("Undo")?.target == nil, "the first responder (the field editor) gets the action")
        let app = EditMenu.make().items.first?.submenu
        #expect(app?.items.contains { $0.keyEquivalent == "q" } == false, "no ⌘Q in the panel")
    }

    @Test func onlyCommandSShiftCommandSAndCommandDSave() {
        let s = 1, d = 2, a = 0, c = 8, v = 9, z = 6, x = 7
        #expect(PanelController.saveKey(keyCode: s, flags: .command, searching: true) == false, "⌘S: the query")
        #expect(PanelController.saveKey(keyCode: s, flags: [.command, .shift], searching: true) == true, "⇧⌘S: the clipboard")
        #expect(PanelController.saveKey(keyCode: d, flags: .command, searching: true) == true, "⌘D: the clipboard too")
        #expect(PanelController.saveKey(keyCode: s, flags: [.command, .capsLock], searching: true) == false)
        #expect(PanelController.saveKey(keyCode: s, flags: [.command, .shift, .capsLock], searching: true) == true)
        // the edit keys go on to the Edit menu and the field editor
        for k in [a, c, v, z, x] { #expect(PanelController.saveKey(keyCode: k, flags: .command, searching: true) == nil) }
        #expect(PanelController.saveKey(keyCode: z, flags: [.command, .shift], searching: true) == nil)
        #expect(PanelController.saveKey(keyCode: d, flags: [.command, .shift], searching: true) == nil)
        #expect(PanelController.saveKey(keyCode: s, flags: [.command, .option], searching: true) == nil)
        #expect(PanelController.saveKey(keyCode: s, flags: [.command, .shift, .option], searching: true) == nil)
        #expect(PanelController.saveKey(keyCode: s, flags: .control, searching: true) == nil)
        #expect(PanelController.saveKey(keyCode: s, flags: [.command, .shift], searching: false) == nil)
        #expect(PanelController.saveKey(keyCode: s, flags: .command, searching: false) == nil, "only in search")
    }

    @Test func vaultToggles() {
        var c = Config()
        let all = VaultTools(vaultFile: true, server: true, abhyasa: true)
        let l = VaultToggles.lines(c, all)
        #expect(l.map(\.key) == [.vault, .hybrid, .abhyasa], "no setup line when the server is there")
        #expect(l.map(\.line.title) == ["Search the Vault", "Search by Meaning, Save Notes", "Open in Abhyasa"])
        #expect(l.map(\.line.checked) == [true, true, true] && l.allSatisfy(\.line.enabled), "a missing key: on when the tool is there")
        #expect(VaultToggles.change(.abhyasa, c)! == ("abhyasa", "enabled", "false"))
        #expect(VaultToggles.change(.vault, c)! == ("vault", "enabled", "false"))
        #expect(VaultToggles.change(.hybrid, c)! == ("vault", "mcp", "false"))
        #expect(VaultToggles.change(.setup, c) == nil)
        // an explicit false stays off
        c.vault.mcp = false
        c.abhyasa.enabled = false
        #expect(VaultToggles.lines(c, all).map(\.line.checked) == [true, false, false])
        #expect(VaultToggles.change(.hybrid, c)! == ("vault", "mcp", "true"))
        c.vault.enabled = false
        #expect(VaultToggles.lines(c, all).map(\.line.enabled) == [true, false, false], "the vault options need vault search")
    }

    /// The menu lines in each state: a missing tool is a disabled line that tells what it needs.
    @Test func vaultLinesForMissingTools() {
        let c = Config()
        func titles(_ t: VaultTools, settingUp: Bool = false) -> [String] { VaultToggles.lines(c, t, settingUp: settingUp).map(\.line.title) }
        func enabled(_ t: VaultTools) -> [Bool] { VaultToggles.lines(c, t).map(\.line.enabled) }
        let noServer = VaultTools(vaultFile: true, server: false, abhyasa: true)
        #expect(titles(noServer) == ["Search the Vault", "Search by Meaning (needs the vault server)", "Open in Abhyasa", "Set Up the Vault…"])
        #expect(enabled(noServer) == [true, false, true, true])
        #expect(VaultToggles.lines(c, noServer).last?.key == .setup)
        #expect(titles(noServer, settingUp: true).last == "Setting Up the Vault…")
        #expect(VaultToggles.lines(c, noServer, settingUp: true).last?.line.enabled == false, "one setup at a time")
        let noApp = VaultTools(vaultFile: true, server: true, abhyasa: false)
        #expect(titles(noApp) == ["Search the Vault", "Search by Meaning, Save Notes", "Get the Abhyasa App…"])
        #expect(enabled(noApp) == [true, true, true] && VaultToggles.lines(c, noApp)[2].line.checked == false, "a link to the download page")
        #expect(VaultToggles.abhyasaDownload.absoluteString == "https://github.com/vedicreader/abhyasa#download")
        let noFile = VaultTools(vaultFile: false, server: true, abhyasa: true)
        #expect(titles(noFile) == ["Search the Vault (no vault file)", "Search by Meaning, Save Notes", "Open in Abhyasa"])
        #expect(enabled(noFile) == [false, true, false], "the server can save the first note, which makes the file")
        #expect(VaultToggles.lines(c, noFile).map(\.line.checked) == [false, true, false])
        let none = VaultTools(vaultFile: false, server: false, abhyasa: false)
        #expect(titles(none) == ["Search the Vault (no vault file)", "Search by Meaning (needs the vault server)",
                                 "Get the Abhyasa App…", "Set Up the Vault…"])
        #expect(enabled(none) == [false, false, true, true])
    }

    @Test func detectsTheVaultTools() {
        var c = Config()
        c.vault.path = "/v/vault.db"
        let home = NSHomeDirectory()
        func t(files: [String], exec: [String], abhyasa: Bool = false) -> VaultTools {
            VaultTools.detect(c, env: [:], fileExists: files.contains, isExecutable: exec.contains) { abhyasa }
        }
        #expect(t(files: [], exec: []) == VaultTools(vaultFile: false, server: false, abhyasa: false))
        #expect(t(files: ["/v/vault.db"], exec: ["\(home)/.local/bin/vishalakshi-mcp"], abhyasa: true) == VaultTools(vaultFile: true, server: true, abhyasa: true))
        #expect(t(files: [], exec: ["/usr/local/bin/vishalakshi-mcp"]).server)
        c.vault.mcpCommand = "/opt/x/mcp"
        #expect(!t(files: [], exec: ["/usr/local/bin/vishalakshi-mcp"]).server, "mcp_command wins over the usual places")
        c.vault.mcpURL = "http://127.0.0.1:8000/mcp"
        #expect(t(files: [], exec: []).server, "a server address counts as a server")
        c.vault.path = ""
        #expect(VaultTools.detect(c, env: ["VISHALAKSHI_VAULT": "/e/v.db"], fileExists: { $0 == "/e/v.db" }, isExecutable: { _ in false }) { false }.vaultFile)
    }

    @Test func setUpTheVaultFindsUVAndRunsOneCommand() {
        let home = NSHomeDirectory()
        #expect(VaultSetup.findUV { _ in false } == nil)
        #expect(VaultSetup.findUV { $0 == "\(home)/.local/bin/uv" || $0 == "/usr/local/bin/uv" } == "\(home)/.local/bin/uv")
        #expect(VaultSetup.findUV { _ in true } == "/opt/homebrew/bin/uv")
        #expect(VaultSetup.message(uv: nil).contains("brew install uv"))
        #expect(VaultSetup.message(uv: "/opt/homebrew/bin/uv").contains("uv tool install vishalakshi"))
        final class Runner: CommandRunning {
            var calls: [(String, [String], TimeInterval)] = []
            var out: String?
            func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? { calls.append((path, args, timeout)); return out }
        }
        let r = Runner()
        r.out = "Installed 2 executables"
        #expect(VaultSetup.run(uv: "/opt/homebrew/bin/uv", runner: r) == VaultSetup.done)
        #expect(r.calls.count == 1 && r.calls[0].0 == "/opt/homebrew/bin/uv" && r.calls[0].1 == ["tool", "install", "vishalakshi"])
        #expect(r.calls[0].2 >= 300, "a download can take minutes")
        r.out = nil
        #expect(VaultSetup.run(uv: "/opt/homebrew/bin/uv", runner: r) == VaultSetup.failed)
    }

    @Test func saveHintShowsOnlyWithAWriter() {
        let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
        #expect(!s.canSave)
        s.setWriter(NoWriter())
        #expect(s.canSave && SearchModel.saveHint.contains("⌘S  Save the query") && SearchModel.saveHint.contains("⇧⌘S  Save the clipboard"))
    }
}

private final class Recorder: VaultWriting, @unchecked Sendable {
    var saved: [(String, String)] = []
    var fail = false
    func save(text: String, title: String) async throws -> String {
        if fail { throw SanketaVault.MCPError.timeout }
        saved.append((text, title)); return title.isEmpty ? text : title
    }
}

@MainActor @Suite struct SaveToVaultTests {
    func until(_ cond: () -> Bool) async { for _ in 0..<150 where !cond() { try? await Task.sleep(for: .milliseconds(20)) } }

    @Test func commandSSavesTheQueryAndCommandDTheClipboard() async {
        let pb = NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)"))
        let s = SearchModel(pasteboard: pb)
        #expect(!s.saveToVault(clipboard: false), "no writer: no save")
        let r = Recorder()
        s.setWriter(r)
        #expect(!s.saveToVault(clipboard: false) && s.note == "Type the text to save.")
        s.query = "tmux prefix d detaches"
        #expect(s.saveToVault(clipboard: false))
        await until { s.note?.hasPrefix("Saved") == true }
        #expect(s.note == "Saved in the vault: \u{201C}tmux prefix d detaches\u{201D}.")
        pb.clearContents()
        #expect(!s.saveToVault(clipboard: true) && s.note == "The clipboard has no text to save.")
        pb.setString("long text from the clipboard", forType: .string)
        #expect(s.saveToVault(clipboard: true))
        await until { r.saved.count == 2 }
        #expect(r.saved.map(\.0) == ["tmux prefix d detaches", "long text from the clipboard"])
        #expect(r.saved.map(\.1) == ["", "tmux prefix d detaches"], "the query is the clipboard note's title")
        r.fail = true
        s.saveToVault(clipboard: false)
        await until { s.note?.hasPrefix("Sanketa could not") == true }
        #expect(s.note == "Sanketa could not save in the vault. The vault server did not answer in time.")
    }
}

private struct NoWriter: VaultWriting { func save(text: String, title: String) async throws -> String { title } }
