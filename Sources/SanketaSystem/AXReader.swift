import AppKit
import ApplicationServices
import SanketaCore

/// Lazily-read AX menu node: children are fetched only when the walker asks.
struct AXMenuNode: MenuNode {
    let el: AXUIElement
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    var title: String? { Self.attr(el, kAXTitleAttribute) as? String }
    var shortcut: String? {
        let ch = Self.attr(el, kAXMenuItemCmdCharAttribute) as? String
        let vk = (Self.attr(el, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber)?.intValue
        let gl = (Self.attr(el, kAXMenuItemCmdGlyphAttribute) as? NSNumber)?.intValue
        let mods = (Self.attr(el, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        return MenuKeys.format(char: ch, virtualKey: vk, modifiers: mods, glyph: gl)
    }
    var children: [MenuNode] {
        let kids = Self.attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
        // a menu bar item / menu item wraps its items in a single AXMenu child; flatten it
        return kids.flatMap { k -> [MenuNode] in
            (Self.attr(k, kAXRoleAttribute) as? String) == kAXMenuRole ? AXMenuNode(el: k).children : [AXMenuNode(el: k)]
        }
    }
}

public enum AXReader {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func promptForTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func menuShortcuts(pid: pid_t) -> [MenuShortcut] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = AXMenuNode.attr(app, kAXMenuBarAttribute) else { return [] }
        let items = AXMenuNode(el: bar as! AXUIElement).children
        return MenuKeys.walk(Array(items.dropFirst()))
    }

    public static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let w = AXMenuNode.attr(app, kAXFocusedWindowAttribute) else { return nil }
        return AXMenuNode.attr(w as! AXUIElement, kAXTitleAttribute) as? String
    }
}
