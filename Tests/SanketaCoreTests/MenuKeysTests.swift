import Testing
@testable import SanketaCore

struct FakeNode: MenuNode {
    var title: String?
    var shortcut: String?
    var kids: [FakeNode] = []
    var children: [MenuNode] { kids }
    var enabled = true
}

@Suite struct MenuKeysTests {
    /// Real Conterm values (conterm-shortcuts-investigation.md): bit 16 is the Globe/fn modifier.
    @Test func formatGlobeModifier() {
        #expect(MenuKeys.format(char: "F", virtualKey: nil, modifiers: 24) == "🌐F")              // Enter Full Screen
        #expect(MenuKeys.format(char: "F", virtualKey: nil, modifiers: 28) == "🌐⌃F")             // Fill
        #expect(MenuKeys.format(char: "C", virtualKey: nil, modifiers: 28) == "🌐⌃C")             // Center
        #expect(MenuKeys.format(char: nil, virtualKey: 123, modifiers: 28) == "🌐⌃←")             // Move & Resize › Left
        #expect(MenuKeys.format(char: nil, virtualKey: 123, modifiers: 29) == "🌐⌃⇧←")            // Left & Right
        #expect(MenuKeys.format(char: nil, virtualKey: 123, modifiers: 31) == "🌐⌃⌥⇧←")           // Left & Quarters
        #expect(MenuKeys.format(char: "H", virtualKey: nil, modifiers: 2) == "⌥⌘H")               // Hide Others
        #expect(KeyNotation.display("🌐⌃←") == "🌐⌃←" && KeyNotation.display("🌐F") == "🌐F")
    }

    @Test func disabledItemsAreKeptAndMarked() {
        let menu = FakeNode(title: "Window", kids: [
            FakeNode(title: "Fill", shortcut: "🌐⌃F"),
            FakeNode(title: "Return to Previous Size", shortcut: "🌐⌃R", enabled: false),
        ])
        let s = MenuKeys.walk([menu])
        #expect(s.map(\.enabled) == [true, false])
        let p = MenuKeys.pack(bundleID: "app.conterm.Conterm", name: "Conterm", shortcuts: s)
        #expect(p.keys.map(\.enabled) == [nil, false] && p.keys[1].action == "Return to Previous Size")
    }

    @Test func formatCmdShiftS() { #expect(MenuKeys.format(char: "s", virtualKey: nil, modifiers: 1) == "⇧⌘S") }
    @Test func formatCtrlOptNoCmd() { #expect(MenuKeys.format(char: "t", virtualKey: nil, modifiers: 4|2|8) == "⌃⌥T") }
    @Test func formatVirtualKeyArrow() { #expect(MenuKeys.format(char: "", virtualKey: 126, modifiers: 0) == "⌘↑") }
    @Test func formatNothingIsNil() {
        #expect(MenuKeys.format(char: nil, virtualKey: nil, modifiers: 0) == nil)
        #expect(MenuKeys.format(char: "", virtualKey: 9999, modifiers: 0) == nil)
    }
    @Test func formatPrivateUseArrow() { #expect(MenuKeys.format(char: "\u{F700}", virtualKey: nil, modifiers: 0) == "⌘↑") }
    @Test func formatFKeyAndGlyph() {
        #expect(MenuKeys.format(char: "", virtualKey: 122, modifiers: 0) == "⌘F1")
        #expect(MenuKeys.format(char: "\u{F704}", virtualKey: nil, modifiers: 0) == "⌘F1")
        #expect(MenuKeys.format(char: "", virtualKey: nil, modifiers: 0, glyph: 0x17) == "⌘⌫")
    }

    @Test func emptyPathDoesNotCrash() {
        let p = MenuKeys.pack(bundleID: "com.x", name: "X", shortcuts: [MenuShortcut(path: [], keys: "⌘K")])
        #expect(p.keys == [KeyEntry(keys: "⌘K", action: "", group: nil)])
    }

    @Test func menuPackGroups() {
        let s = [MenuShortcut(path: ["Format", "Font", "Bold"], keys: "⌘B"),
                 MenuShortcut(path: ["Format", "Font", "Italic"], keys: "⌘I"),
                 MenuShortcut(path: ["File", "Save"], keys: "⌘S")]
        let p = MenuKeys.pack(bundleID: "com.x", name: "X", shortcuts: s)
        #expect(p.id == "app:com.x")
        #expect(p.keys.count == 3)
        #expect(p.keys[0].action == "Font › Bold" && p.keys[0].group == "Format")
        #expect(p.keys[2].action == "Save" && p.keys[2].group == "File")
    }

    @Test func walkRespectsCaps() {
        func tree(_ depth: Int, _ width: Int) -> [FakeNode] {
            (0..<width).map { FakeNode(title: "i\($0)", shortcut: "⌘A", kids: depth > 1 ? tree(depth - 1, width) : []) }
        }
        // 5^6 leaves, depth 6
        let out = MenuKeys.walk(tree(6, 5))
        #expect(out.count <= 2000 && !out.isEmpty)
        #expect(out.allSatisfy { $0.path.count <= 4 })
    }

    @Test func walkCapBoundsChildAccess() {
        final class Counter: @unchecked Sendable { var n = 0 }
        struct Lazy: MenuNode {
            let c: Counter; let depth: Int
            var title: String? { "t" }
            var shortcut: String? { nil }
            var children: [MenuNode] { c.n += 1; return depth > 0 ? (0..<10).map { _ in Lazy(c: c, depth: depth - 1) } : [] }
        }
        let c = Counter()
        _ = MenuKeys.walk([Lazy(c: c, depth: 10)], maxDepth: 10, maxItems: 100)
        #expect(c.n <= 100)
    }
}
