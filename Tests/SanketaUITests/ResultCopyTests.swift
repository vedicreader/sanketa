import AppKit
import Foundation
import Testing
import SwiftUI
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// Copy gives the text the user types: a tip's snippet or a key's command. Keys alone are not copied.
/// A click on a search result shows all its text; it does not close search.
@MainActor struct ResultCopyTests {
    func search() throws -> (SearchModel, NSPasteboard) {
        let pb = NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)"))
        let s = SearchModel(pasteboard: pb)
        s.setSource(library: PackLibrary(packs: try packs()), context: try context(["fish", "tmux", "Terminal"]))
        return (s, pb)
    }

    @Test func copyTextIsTheCommandOrSnippetNeverTheKeys() throws {
        let tmux = try #require(try packs()["tmux"])
        let items = SearchItem.items(from: tmux)
        let split = try #require(items.first { $0.title == "Split pane left/right" })
        #expect(split.command == "split-window -h" && split.copyText == "split-window -h")
        let bare = SearchItem(packID: "app:x", packName: "X", kind: .key, title: "New", detail: "⌘N")
        #expect(bare.copyText == nil)
        let tip = SearchItem(packID: "claude", packName: "Claude Code", kind: .tip, title: "Resume", detail: "claude -c")
        #expect(tip.copyText == "claude -c")
        #expect(PanelModel.copyText(KeyEntry(keys: "⌘N", action: "New")) == nil)
        #expect(PanelModel.copyText(KeyEntry(keys: "prefix %", action: "Split", command: "split-window -h")) == "split-window -h")
        #expect(TipCard.copyText(SearchItem(packID: "tmux", packName: "tmux", kind: .key, title: "Split", detail: "prefix %")) == nil)
    }

    @Test func returnCopiesTheCommandAndAKeyWithNoCommandCopiesNothing() throws {
        let (s, pb) = try search()
        s.query = "split pane left"
        #expect(s.activate()?.title == "Split pane left/right")
        #expect(pb.string(forType: .string) == "split-window -h")
        pb.clearContents(); pb.setString("before", forType: .string)
        s.setSource(library: PackLibrary(packs: [:]), context: Context(appName: "X", bundleID: "x", layers: [], packs: [
            MenuKeys.pack(bundleID: "x", name: "X", shortcuts: [MenuShortcut(path: ["File", "New Window"], keys: "⌘N")])], axTrusted: true))
        s.query = "new window"
        #expect(s.selected != nil && s.activate() == nil)
        #expect(pb.string(forType: .string) == "before")
    }

    @Test func clickOpensTheResultAndASecondClickClosesIt() throws {
        let (s, _) = try search()
        s.query = "pane"
        #expect(s.results.count >= 2)
        s.click(1)
        #expect(s.selection == 1 && s.expanded == s.results[1].id)
        s.click(0)
        #expect(s.selection == 0 && s.expanded == s.results[0].id, "one result open at a time")
        s.click(0)
        #expect(s.expanded == nil)
        s.click(1); s.query = "split"
        #expect(s.expanded == nil, "a new query starts with short rows")
    }

    @Test func theCommandStaysOnTheMac() throws {
        let tmux = try #require(try packs()["tmux"])
        let (p, _) = ChoicePrompt.build(task: .search("split"), candidates: SearchItem.items(from: tmux), maxPicks: 3)
        #expect(!p.lines.contains { $0.contains("split-window") })
    }

    @Test func resultRowShowsCopyOnHoverOnlyWhenThereIsTextToCopy() {
        let tip = SearchItem(packID: "claude", packName: "Claude Code", kind: .tip, title: "Resume", detail: "claude -c")
        let bare = SearchItem(packID: "app:x", packName: "X", kind: .key, title: "New", detail: "⌘N")
        func row(_ i: SearchItem, hover: Bool) -> ResultRow { ResultRow(item: i, selected: false, hover: hover) }
        #expect(CopyButtonPlacementTests.ink(row(tip, hover: false), trailing: 12) == 0)
        #expect(CopyButtonPlacementTests.ink(row(tip, hover: true), trailing: 12) > 0)
        #expect(CopyButtonPlacementTests.ink(row(bare, hover: true), trailing: 12) == 0)
    }

    @Test func keyRowHasNoCopyButtonWithoutACommand() {
        let k = KeyEntry(keys: "⌘K", action: "Clear")
        #expect(CopyButtonPlacementTests.ink(KeyRow(key: k, prefix: nil, expanded: false, toggle: {}, copy: { _ in }, hover: true), trailing: 12) == 0)
    }
}
