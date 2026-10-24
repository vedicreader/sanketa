import Foundation
import Carbon.HIToolbox

public struct MenuShortcut: Hashable {
    public var path: [String]
    public var keys: String
    public init(path: [String], keys: String) { self.path = path; self.keys = keys }
}

public protocol MenuNode {
    var title: String? { get }
    var shortcut: String? { get }
    var children: [MenuNode] { get }
}

public enum MenuKeys {
    static let fKeyVirtual = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    static let virtualNames: [Int: String] = {
        var d = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        for (i, k) in fKeyVirtual.enumerated() { d[k] = "F\(i + 1)" }
        return d
    }()
    static let glyphNames: [Int: String] = {
        var d: [Int: String] = [kMenuReturnGlyph: "↩", kMenuTabRightGlyph: "⇥", kMenuDeleteLeftGlyph: "⌫",
            kMenuEscapeGlyph: "⎋", kMenuDeleteRightGlyph: "⌦", kMenuSpaceGlyph: "Space",
            kMenuUpArrowGlyph: "↑", kMenuDownArrowGlyph: "↓", kMenuLeftArrowGlyph: "←", kMenuRightArrowGlyph: "→"]
        for i in 0..<12 { d[kMenuF1Glyph + i] = "F\(i + 1)" }
        return d
    }()
    /// AppKit private-use function-key characters (0xF700...)
    static func privateUse(_ u: UInt32) -> String? {
        switch u {
        case 0xF700: "↑"
        case 0xF701: "↓"
        case 0xF702: "←"
        case 0xF703: "→"
        case 0xF704...0xF70F: "F\(u - 0xF704 + 1)"
        case 0xF728: "⌦"
        default: nil
        }
    }

    public static func format(char: String?, virtualKey: Int?, modifiers: Int, glyph: Int? = nil) -> String? {
        var key: String?
        if let c = char, let u = c.unicodeScalars.first {
            if (0xF700...0xF8FF).contains(u.value) { key = privateUse(u.value) }
            else if u.value == 0x0D || u.value == 0x03 { key = "↩" }
            else if u.value == 0x09 { key = "⇥" }
            else if u.value == 0x7F || u.value == 0x08 { key = "⌫" }
            else if u.value == 0x1B { key = "⎋" }
            else if u.value == 0x20 { key = "Space" }
            else if u.value > 0x20 { key = c.uppercased() }
        }
        if key == nil, let v = virtualKey { key = virtualNames[v] }
        if key == nil, let g = glyph { key = glyphNames[g] }
        guard let key else { return nil }
        var s = ""
        if modifiers & 4 != 0 { s += "⌃" }
        if modifiers & 2 != 0 { s += "⌥" }
        if modifiers & 1 != 0 { s += "⇧" }
        if modifiers & 8 == 0 { s += "⌘" }
        return s + key
    }

    /// Depth-first walk; `children` is only read for nodes visited within the caps.
    public static func walk(_ topMenus: [MenuNode], maxDepth: Int = 4, maxItems: Int = 2000) -> [MenuShortcut] {
        var out: [MenuShortcut] = [], visited = 0
        func go(_ n: MenuNode, _ path: [String]) {
            guard visited < maxItems else { return }
            visited += 1
            guard let t = n.title, !t.isEmpty else { return }
            let p = path + [t]
            if let k = n.shortcut { out.append(MenuShortcut(path: p, keys: k)) }
            guard p.count < maxDepth else { return }
            for c in n.children { go(c, p); if visited >= maxItems { return } }
        }
        for m in topMenus { go(m, []) }
        return out
    }

    public static func pack(bundleID: String, name: String, shortcuts: [MenuShortcut]) -> Pack {
        Pack(id: "app:\(bundleID)", name: name,
             keys: shortcuts.map { KeyEntry(keys: $0.keys, action: $0.path.dropFirst().joined(separator: " › "), group: $0.path[0]) })
    }
}
