import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

let tmuxTOML = """
id = "tmux"
name = "tmux"
processes = ["tmux"]
prefix = "C-b"

[[keys]]
keys = "prefix %"
action = "Split pane left/right"
group = "Panes"

[[keys]]
keys = "prefix c"
action = "New window"
group = "Windows"

[[keys]]
keys = "prefix z"
action = "Zoom pane"
group = "Panes"
"""

let fishTOML = """
id = "fish"
name = "fish"
processes = ["fish"]

[[keys]]
keys = "alt+right"
action = "Accept autosuggestion word"

[[tips]]
title = "Loop over files"
snippet = "for f in *.log; echo $f; end"
explain = "fish for-loop; no do/done needed"
tags = ["loops"]
"""

let htopTOML = """
id = "htop"
name = "htop"
processes = ["htop"]

[[keys]]
keys = "F6"
action = "Sort by column"
"""

func packs() throws -> [String: Pack] {
    Dictionary(uniqueKeysWithValues: try [tmuxTOML, fishTOML, htopTOML].map { try PackLibrary.decode(Data($0.utf8)) }.map { ($0.id, $0) })
}

func tempURL(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-ui-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d.appendingPathComponent(name)
}

let terminal = MenuKeys.pack(bundleID: "com.apple.Terminal", name: "Terminal",
                             shortcuts: [MenuShortcut(path: ["Shell", "New Window"], keys: "⌘N")])

func context(_ names: [String]) throws -> Context {
    let p = try packs()
    let layers = names.map { n -> Layer in
        switch n {
        case "Terminal": Layer(kind: .terminal, name: n, packID: terminal.id)
        case "tmux": Layer(kind: .multiplexer, name: n, packID: n)
        case "fish": Layer(kind: .shell, name: n, packID: n)
        default: Layer(kind: .program, name: n, packID: n)
        }
    }
    return Context(appName: "Terminal", bundleID: "com.apple.Terminal", layers: layers,
                   packs: names.map { $0 == "Terminal" ? terminal : p[$0]! }, axTrusted: true)
}

@MainActor func controller() throws -> PanelController {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let model = PanelModel(tips: TipStore(url: try tempURL("tips.json")))
    let search = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
    search.setSource(library: PackLibrary(packs: try packs()))
    return PanelController(model: model, search: search)
}

/// CPU time of the calling thread; the panel's SwiftUI and AppKit work runs on the main thread.
func threadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
    let port = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, port) }
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
    }
    return Double(info.user_time.seconds + info.system_time.seconds)
        + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
}

@MainActor @Suite(.serialized) struct PanelTests {
    @Test func visiblePanelIdlesWithoutCPU() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.model.update(try context(["htop", "tmux", "fish", "Terminal"]))
        c.show()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let t0 = threadCPUSeconds()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        #expect(threadCPUSeconds() - t0 < 0.1)   // main thread under ~3% over 3 s, generous for a loaded machine
    }

    @Test func panelShowDoesNotStealFocus() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.show()
        #expect(c.panel.isVisible)
        #expect(NSApp.keyWindow !== c.panel)
        #expect(!c.panel.isKeyWindow)
        #expect(!NSApp.isActive)
        #expect(c.panel.contentView is NSGlassEffectView && !c.panel.isOpaque)
    }

    @Test func beginSearchMakesPanelKeyAndEndSearchResigns() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.show()
        c.beginSearch(previousApp: nil)
        #expect(c.panel.isKeyWindow)
        #expect(c.field.currentEditor() != nil && c.panel.firstResponder === c.field.currentEditor())
        // typing goes through the field into the search model
        (c.field.currentEditor() as? NSTextView)?.insertText("split", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(c.search.query == "split")
        #expect(c.search.selected?.title == "Split pane left/right")
        c.endSearch()
        #expect(!c.panel.isKeyWindow)
        #expect(c.panel.isVisible)
        #expect(c.search.query.isEmpty && c.field.stringValue.isEmpty && c.search.results.isEmpty)
        #expect(!c.searching)
    }

    @Test func returnCopiesAndEscapeEnds() throws {
        let c = try controller()
        defer { c.panel.orderOut(nil) }
        c.beginSearch(previousApp: nil)
        let ed = try #require(c.field.currentEditor() as? NSTextView)
        ed.insertText("pane", replacementRange: NSRange(location: NSNotFound, length: 0))
        ed.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(c.search.selected?.title == "Zoom pane")
        ed.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(c.search.pasteboard.string(forType: .string) == "prefix z")
        #expect(!c.panel.isKeyWindow && !c.searching)
        c.beginSearch(previousApp: nil)
        try #require(c.field.currentEditor() as? NSTextView).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!c.panel.isKeyWindow && !c.searching && c.panel.isVisible)
    }

    @Test func hotkeyRegistersAndConflictReturnsFalse() throws {
        let a = HotkeyCenter(), b = HotkeyCenter()
        defer { a.unregisterAll(); b.unregisterAll() }
        let h = try #require(Hotkey.parse("ctrl+opt+cmd+shift+f12"))
        #expect(h.keyCode == UInt32(kVK_F12))
        #expect(a.register(h) {})
        #expect(!b.register(h) {})
        a.unregisterAll()
        #expect(b.register(h) {})
    }

    @Test func searchModelCopiesSelectedDetail() throws {
        let pb = NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let s = SearchModel(pasteboard: pb)
        s.setSource(library: PackLibrary(packs: try packs()), context: try context(["fish", "Terminal"]))
        s.query = "split"
        let first = try #require(s.results.first)
        #expect(first.packID == "tmux" && first.title == "Split pane left/right" && first.detail == "prefix %")
        #expect(s.activate() == first)
        #expect(pb.string(forType: .string) == "prefix %")
        s.query = "pane"
        #expect(s.results.count == 2)
        s.move(-1); #expect(s.selection == 0)
        s.move(5); #expect(s.selection == 1)
        s.activate()
        #expect(pb.string(forType: .string) == "prefix z")
        s.query = "zzzqqq"
        #expect(s.results.isEmpty && s.activate() == nil)
        #expect(pb.string(forType: .string) == "prefix z")
    }

    @Test func panelModelSectionsFollowContext() throws {
        let url = try tempURL("tips.json")
        let m = PanelModel(tips: TipStore(url: url), seed: 7)
        m.update(try context(["htop", "tmux", "fish", "Terminal"]))
        #expect(m.sections.map(\.pack.id) == ["htop", "tmux", "fish", "app:com.apple.Terminal"])
        let tmux = m.sections[1]
        #expect(tmux.groups.map(\.name) == ["Panes", "Windows"])
        #expect(tmux.groups[0].keys.map(\.action) == ["Split pane left/right", "Zoom pane"])
        #expect(m.sections[3].groups.map(\.name) == ["Shell"])
        let seed = m.seed
        m.update(try context(["fish", "Terminal"]))
        #expect(m.sections.map(\.pack.id) == ["fish", "app:com.apple.Terminal"])
        #expect(m.seed != seed)

        let tip = try #require(m.tip)
        m.mark(.known)
        #expect(TipStore(url: url).mark(tip.id) == .known)
        #expect(m.tip != nil && m.tip != tip)
        for s in 0..<30 as Range<UInt64> {
            #expect(!m.tips.pick(from: m.tipPool, count: 3, seed: s).contains(tip))
        }
        #expect(!m.showsFooter)
        m.hotkeyConflict = "ctrl+opt+k"
        #expect(m.showsFooter)
    }
}
