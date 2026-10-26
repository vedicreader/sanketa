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
        let l = VaultToggles.lines(c)
        #expect(l.map(\.key) == [.vault, .hybrid, .abhyasa])
        #expect(l.map(\.line.checked) == [true, true, false], "abhyasa is off by default")
        #expect(VaultToggles.change(.abhyasa, c) == ("abhyasa", "enabled", "true"))
        #expect(VaultToggles.change(.vault, c) == ("vault", "enabled", "false"))
        #expect(VaultToggles.change(.hybrid, c) == ("vault", "mcp", "false"))
        c.vault.enabled = false
        #expect(VaultToggles.lines(c).map(\.line.enabled) == [true, false, false], "the vault options need vault search")
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
