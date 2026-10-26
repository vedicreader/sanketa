import AppKit
import Foundation
import Testing
import SanketaCore
@testable import SanketaUI
import SanketaVault

private struct Writer: VaultWriting {
    var fail = false
    func save(text: String, title: String) async throws -> String {
        if fail { throw SanketaVault.MCPError.timeout }
        return title.isEmpty ? text : title
    }
}

@MainActor private final class Toasts { var lines: [String] = [] }

private func temp(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-toast-\(UUID().uuidString)-\(name)")
}

private let app = PackMaker.App(name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee", version: "5.13")

/// An answer of the model with one key, or with two keys that clash (a draft).
private func answer(draft: Bool) -> String {
    let k = { (a: String) in "[[keys]]\nkeys = \"⌃S\"\naction = \"\(a)\"\ngroup = \"Editor\"\n" }
    return "id = \"rawtherapee\"\nname = \"RawTherapee\"\n\n" + k("Save the image") + (draft ? "\n" + k("Save again") : "")
}

@MainActor private func maker(_ dir: URL, draft: Bool, toasts: Toasts) async -> PackMakerModel {
    var c = LLMConfig()
    c.openai = true
    let text = answer(draft: draft)
    let m = PackMakerModel(.init(app: app, menu: [], existing: nil, config: c, provider: "OpenAI", onDeviceReady: false,
                                 sendOpenAI: { _ in text }, sendOnDevice: nil, packsDir: dir,
                                 pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")),
                                 confirmReplace: { _ in true }, saved: { _ in }, toast: { toasts.lines.append($0) }))
    m.requestClose = {}
    m.send(.openAI)
    await m.work?.value
    return m
}

/// Each save shows a toast in the panel: what it saved, or why it did not. It stays for 4 s, and longer under the pointer.
@MainActor @Suite(.serialized) struct SaveToastTests {
    @Test func saveToastStaysFourSecondsAndWhileThePointerIsOnIt() throws {
        let m = PanelModel(tips: TipStore(url: temp("tips.json")), seed: 1)
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        m.now = { clock }
        m.showSaveToast("Saved in the vault: \u{201C}x\u{201D}.")
        #expect(m.toast == "Saved in the vault: \u{201C}x\u{201D}.")
        clock += 3.9
        m.expireToast()
        #expect(m.toast != nil, "still there before 4 s")
        clock += 0.1
        m.expireToast()
        #expect(m.toast == nil)
        // under the pointer it stays; after the pointer leaves, it goes after toastSeconds
        m.showSaveToast("Saved rawtherapee.toml.")
        m.holdToast(true)
        clock += 10
        m.expireToast()
        #expect(m.toast == "Saved rawtherapee.toml.")
        m.holdToast(false)
        m.expireToast()
        #expect(m.toast != nil)
        clock += PanelModel.toastSeconds
        m.expireToast()
        #expect(m.toast == nil)
        // "Copied" keeps its short time
        m.copy("x")
        clock += PanelModel.toastSeconds
        m.expireToast()
        #expect(m.toast == nil && PanelModel.saveToastSeconds == 4)
    }

    @Test func vaultSavesToastTheTitleOrTheReason() async {
        let pb = NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)"))
        let s = SearchModel(pasteboard: pb), t = Toasts()
        s.toast = { t.lines.append($0) }
        s.setWriter(Writer())
        s.saveToVault(clipboard: false)
        #expect(t.lines == ["Type the text to save."])
        s.query = "tmux prefix d detaches"
        s.saveToVault(clipboard: false)
        for _ in 0..<150 where t.lines.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(t.lines.last == "Saved in the vault: \u{201C}tmux prefix d detaches\u{201D}.")
        // the toast shows also when the query changed before the save ended; the note line does not
        s.setWriter(Writer(fail: true))
        s.saveToVault(clipboard: false)
        s.query = "other"
        for _ in 0..<150 where t.lines.count < 3 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(t.lines.last == "Sanketa could not save in the vault. The vault server did not answer in time.")
        #expect(s.note == nil)
    }

    @Test func packSavesToastTheFileOrTheReason() async throws {
        let dir = temp("packs"), t = Toasts()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = await maker(dir, draft: false, toasts: t)
        m.save()
        #expect(t.lines == ["Saved rawtherapee.toml. The keys show when RawTherapee is in front."])
        let d = await maker(dir, draft: true, toasts: t)
        d.saveDraft()
        #expect(t.lines.last == "Saved rawtherapee.toml.draft. Sanketa does not load a draft.")
        // a file where the folder must be: the save fails, and the toast tells why
        let file = temp("not-a-folder")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let f = await maker(file, draft: false, toasts: t)
        f.save()
        #expect(t.lines.count == 3 && t.lines.last?.hasPrefix("Sanketa cannot write the file:") == true)
    }
}
