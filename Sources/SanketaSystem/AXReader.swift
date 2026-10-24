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
    /// the messaging timeout of each read, in seconds
    public static let timeout: TimeInterval = 0.5

    public static func promptForTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func menuShortcuts(pid: pid_t) -> [MenuShortcut] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        guard let bar = AXMenuNode.attr(app, kAXMenuBarAttribute) else { return [] }
        let items = AXMenuNode(el: bar as! AXUIElement).children
        return MenuKeys.walk(Array(items.dropFirst()))
    }

    public static func focusedWindowTitle(pid: pid_t) -> String? { focusedWindow(pid: pid)?.title }

    /// The focused window's title and identity (`CFHash` of its element, the same for each read of one window).
    public static func focusedWindow(pid: pid_t) -> (title: String?, id: Int)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
        guard let w = AXMenuNode.attr(app, kAXFocusedWindowAttribute) else { return nil }
        return (AXMenuNode.attr(w as! AXUIElement, kAXTitleAttribute) as? String, Int(bitPattern: CFHash(w)))
    }

    /// Attribute names and short values of the focused window and focused element, two levels deep.
    public static func dump(pid: pid_t, depth: Int = 2) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(timeout))
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

/// One background thread whose run loop delivers Accessibility notifications, so a slow app cannot block the main thread.
final class AXLoop: Thread, @unchecked Sendable {
    static let shared: AXLoop = { let t = AXLoop(); t.name = "dev.sanketa.ax"; t.qualityOfService = .utility; t.start(); t.ready.wait(); return t }()
    let ready = DispatchSemaphore(value: 0)
    private(set) var loop: CFRunLoop!

    override func main() {
        loop = CFRunLoopGetCurrent()
        // a timer in the far future keeps the run loop alive while it has no sources
        let keep = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(loop, keep, .defaultMode)
        ready.signal()
        CFRunLoopRun()
    }

    func perform(_ f: @escaping () -> Void) {
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, f)
        CFRunLoopWakeUp(loop)
    }
}

/// Calls `onChange` on the main thread with the focused window title when the app's focused window changes or that
/// window's title changes. Accessibility notifications on `AXLoop`, so nothing polls and the main thread never waits
/// on the app. After the watcher is released, no more calls come.
public final class AXTitleWatcher {
    /// state that the `AXLoop` thread owns
    final class Core: @unchecked Sendable {
        let observer: AXObserver
        let app: AXUIElement
        let onChange: (String?) -> Void
        var window: AXUIElement?
        let lock = NSLock()
        var cancelled = false

        init(observer: AXObserver, app: AXUIElement, onChange: @escaping (String?) -> Void) {
            self.observer = observer; self.app = app; self.onChange = onChange
        }

        var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

        func start() {
            for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverAddNotification(observer, app, n as CFString, refcon)
            }
            watchFocusedWindow()
            CFRunLoopAddSource(AXLoop.shared.loop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }

        func stop() {
            CFRunLoopRemoveSource(AXLoop.shared.loop, AXObserverGetRunLoopSource(observer), .defaultMode)
            if let w = window { AXObserverRemoveNotification(observer, w, kAXTitleChangedNotification as CFString) }
            for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverRemoveNotification(observer, app, n as CFString)
            }
        }

        func watchFocusedWindow() {
            if let w = window { AXObserverRemoveNotification(observer, w, kAXTitleChangedNotification as CFString) }
            window = AXMenuNode.attr(app, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            if let w = window {
                AXUIElementSetMessagingTimeout(w, 0.25)
                AXObserverAddNotification(observer, w, kAXTitleChangedNotification as CFString, refcon)
            }
        }

        func fired(_ note: String) {
            if note != kAXTitleChangedNotification { watchFocusedWindow() }
            let title = window.flatMap { AXMenuNode.attr($0, kAXTitleAttribute) as? String }
            // on the main run loop, not the main queue: it also runs while a caller spins the run loop
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [self] in
                if !lock.withLock({ cancelled }) { onChange(title) }
            }
            CFRunLoopWakeUp(main)
        }
    }

    let core: Core

    public init?(pid: pid_t, onChange: @escaping (String?) -> Void) {
        var o: AXObserver?
        let cb: AXObserverCallback = { _, _, note, refcon in
            guard let refcon else { return }
            Unmanaged<Core>.fromOpaque(refcon).takeUnretainedValue().fired(note as String)
        }
        guard AXObserverCreate(pid, cb, &o) == .success, let o else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        core = Core(observer: o, app: app, onChange: onChange)
        AXLoop.shared.perform { [core] in core.start() }
    }

    deinit {
        core.lock.withLock { core.cancelled = true }
        // the block keeps `core` alive until its source is gone from the loop
        AXLoop.shared.perform { [core] in core.stop() }
    }
}
