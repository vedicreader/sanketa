import AppKit
import SwiftUI
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// Draws the Make a Pack window in each state to PNG files, for design reviews. The window is never shown: the hosting
/// view draws itself into a bitmap. Off in `make test`: run `make shots` (or set `SANKETA_RENDER=1`).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SANKETA_RENDER"] == "1"))
struct PackMakerRenderTests {
    static let out = RenderTests.out.appendingPathComponent("pack-maker")
    static let app = PackMaker.App(name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee", version: "5.13")
    static let menu = [MenuShortcut(path: ["RawTherapee", "Quit RawTherapee"], keys: "⌘Q"), MenuShortcut(path: ["File", "Open…"], keys: "⌘O"),
                       MenuShortcut(path: ["Edit", "Copy"], keys: "⌘C"), MenuShortcut(path: ["View", "Full Screen"], keys: "⌃⌘F")]

    static func key(_ k: String, _ a: String, _ g: String) -> String { "[[keys]]\nkeys = \"\(k)\"\naction = \"\(a)\"\ngroup = \"\(g)\"\n" }
    /// a pack with warnings: few keys and one long action
    static let warned = "id = \"x\"\nname = \"X\"\n\n" + key("Ctrl+s", "Save the image", "Editor") + key("c", "Crop", "Editor")
        + key("b", "Show the image before and after the edit", "Editor") + key("⌘F", "Fit the image to the window", "View")
        + "\n[[tips]]\ntitle = \"Compare\"\nsnippet = \"B\"\nexplain = \"Shows before and after.\"\n"
    static let broken = "id = \"x\"\nname = \"X\"\n\n" + key("⌃S", "Save", "Editor") + key("⌃S", "Save again", "Editor")

    /// A sender that waits until it is stopped.
    static let forever: (String) async throws -> String = { _ in try await Task.sleep(for: .seconds(3600)); return "" }

    static func model(openAI: ((String) async throws -> String)? = forever, onDevice: ((String) async throws -> String)? = forever,
                      dir: URL) -> PackMakerModel {
        var c = LLMConfig(); c.openai = openAI != nil; c.onDevice = onDevice != nil
        return PackMakerModel(.init(app: app, menu: menu, existing: nil, config: c, provider: "OpenAI", onDeviceReady: onDevice != nil,
                                    sendOpenAI: openAI, sendOnDevice: onDevice, packsDir: dir,
                                    pasteboard: NSPasteboard(name: .init("sanketa-shots-\(UUID().uuidString)")),
                                    confirmReplace: { _ in true }, saved: { _ in }))
    }

    static let docs = "Keyboard shortcuts\nCtrl+S saves the image.\nC selects the crop tool.\nB shows before and after."

    /// Each state, made with the public actions of the model and fake senders.
    static func states() async throws -> [(String, PackMakerModel)] {
        var r = [(String, PackMakerModel)]()
        let d = try tempURL("packs")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        // a pack on disk, so the result shows a diff
        try ("id = \"rawtherapee\"\nname = \"RawTherapee\"\napps = [\"com.rawtherapee.RawTherapee\"]\n\n" + key("c", "Crop the image", "Editor")
             + key("x", "Old key", "Editor")).write(to: d.appendingPathComponent("rawtherapee.toml"), atomically: true, encoding: .utf8)

        r.append(("idle", model(dir: d)))
        r.append(("idle-copy-only", model(openAI: nil, onDevice: nil, dir: d)))
        let copied = model(openAI: nil, onDevice: nil, dir: d); copied.copyPrompt(); r.append(("prompt-copied", copied))
        let busyAI = model(dir: d); busyAI.urls = "https://rawpedia.rawtherapee.com/Keyboard_Shortcuts"; busyAI.send(.openAI)
        r.append(("busy-openai", busyAI))
        let busyDev = model(dir: d); busyDev.docs = docs; busyDev.send(.onDevice); r.append(("busy-on-device", busyDev))
        let warn = model(openAI: { _ in warned }, dir: d); warn.send(.openAI); await warn.work?.value; r.append(("result-warnings", warn))
        let err = model(openAI: { _ in broken }, dir: d); err.send(.openAI); await err.work?.value; r.append(("result-errors", err))
        let fail = model(openAI: { _ in throw ChoiceError.http(500) }, dir: d); fail.send(.openAI); await fail.work?.value
        r.append(("error", fail))
        let saved = model(openAI: { _ in warned }, dir: try tempURL("packs2")); saved.send(.openAI); await saved.work?.value; saved.save()
        r.append(("saved", saved))
        return r
    }

    static func bitmap(_ m: PackMakerModel, dark: Bool, size: CGSize) throws -> NSBitmapImageRep {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: PackMakerView(model: m, provider: "OpenAI")
            .background(Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return rep
    }

    @Test func drawStates() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var written = [URL]()
        for (name, m) in try await Self.states() {
            for dark in [false, true] {
                let rep = try Self.bitmap(m, dark: dark, size: PackMakerWindow.size)
                let f = Self.out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                try #require(rep.representation(using: .png, properties: [:])).write(to: f)
                written.append(f)
            }
            m.stop()
        }
        print("render output: \(Self.out.path) (\(written.count) files)")
        #expect(written.allSatisfy { NSImage(contentsOf: $0)?.size.width ?? 0 > 0 })
    }
}
