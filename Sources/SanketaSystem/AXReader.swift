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
    var enabled: Bool { (Self.attr(el, kAXEnabledAttribute) as? Bool) ?? true }
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

    /// Attribute names and short values of the focused window and focused element, two levels deep.
    public static func dump(pid: pid_t, depth: Int = 2) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var out = [String]()
        let first = (AXMenuNode.attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first
        let roots: [(String, CFTypeRef?)] = [(kAXFocusedWindowAttribute, AXMenuNode.attr(app, kAXFocusedWindowAttribute)),
                                             (kAXFocusedUIElementAttribute, AXMenuNode.attr(app, kAXFocusedUIElementAttribute)),
                                             ("AXWindows[0]", first)]
        for (name, v) in roots {
            out.append("[\(name)]")
            guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { out.append("  (none)"); continue }
            dump(v as! AXUIElement, level: 1, depth: depth, into: &out)
        }
        return out
    }

    static func dump(_ el: AXUIElement, level: Int, depth: Int, into out: inout [String]) {
        let pad = String(repeating: "  ", count: level)
        var names: CFArray?
        _ = AXUIElementCopyAttributeNames(el, &names)
        var pid: pid_t = 0
        if AXUIElementGetPid(el, &pid) == .success { out.append("\(pad)(pid) \(pid)") }
        for n in (names as? [String] ?? []) {
            out.append("\(pad)\(n) = \(describe(AXMenuNode.attr(el, n)))")
        }
        guard level < depth else { return }
        for (i, k) in (AXMenuNode.attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(20).enumerated() {
            out.append("\(pad)child \(i):")
            dump(k, level: level + 1, depth: depth, into: &out)
        }
    }

    static func describe(_ v: CFTypeRef?) -> String {
        guard let v else { return "nil" }
        if CFGetTypeID(v) == AXUIElementGetTypeID() {
            return "<\(AXMenuNode.attr(v as! AXUIElement, kAXRoleAttribute) as? String ?? "element")>"
        }
        if let a = v as? [Any] { return "[\(a.count) items]" }
        let s = (v as? String).map { "\"\($0)\"" } ?? "\(v)"
        let one = s.replacingOccurrences(of: "\n", with: "⏎")
        return one.count > 160 ? one.prefix(160) + "…" : one
    }
}

/// Calls `onChange` on the main run loop when the app's focused window changes or that window's title changes.
/// Accessibility notifications, so nothing polls.
public final class AXTitleWatcher {
    let observer: AXObserver
    let app: AXUIElement
    let onChange: () -> Void
    var window: AXUIElement?

    public init?(pid: pid_t, onChange: @escaping () -> Void) {
        var o: AXObserver?
        let cb: AXObserverCallback = { _, _, note, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXTitleWatcher>.fromOpaque(refcon).takeUnretainedValue()
            if (note as String) != kAXTitleChangedNotification { me.watchFocusedWindow() }
            me.onChange()
        }
        guard AXObserverCreate(pid, cb, &o) == .success, let o else { return nil }
        observer = o; app = AXUIElementCreateApplication(pid); self.onChange = onChange
        AXUIElementSetMessagingTimeout(app, 0.5)
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(o, app, n as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        watchFocusedWindow()
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
    }

    func watchFocusedWindow() {
        if let w = window { AXObserverRemoveNotification(observer, w, kAXTitleChangedNotification as CFString) }
        window = AXMenuNode.attr(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
        if let w = window {
            AXObserverAddNotification(observer, w, kAXTitleChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    deinit { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
}
