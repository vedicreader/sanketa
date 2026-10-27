import AppKit
import Combine
import SwiftUI
import SanketaCore
import SanketaSystem

/// Floating glass panel that only becomes key for hotkey-started search.
public final class SanketaPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }
    var onMouseUp: (NSEvent) -> Void = { _ in }

    /// Keys reaching the window itself, i.e. while the layer list (not the field) has focus.
    public override func keyDown(with e: NSEvent) { if !onKey(e) { super.keyDown(with: e) } }

    /// ⌘ keys, also while the field has focus.
    public override func performKeyEquivalent(with e: NSEvent) -> Bool { onKeyEquivalent(e) || super.performKeyEquivalent(with: e) }

    public override func sendEvent(_ e: NSEvent) {
        super.sendEvent(e)
        if e.type == .leftMouseUp { onMouseUp(e) }
    }
}

@MainActor public final class PanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    public let panel: SanketaPanel
    public let field = SearchTextField()
    public let glass = NSGlassEffectView()
    public let model: PanelModel
    public let search: SearchModel
    public private(set) var searching = false
    /// The user hid the panel by hand, or pressed Esc in it.
    public var onDismiss: () -> Void = {}
    var previousApp: NSRunningApplication?
    public var grantAccessibility: () -> Void = {}
    /// opens a pack or config file for editing (a footer line)
    public var openFile: (String) -> Void = { _ in }
    /// makes a first pack for a program with none, then opens it
    public var makePack: (Layer) -> Void = { _ in }
    /// called when search starts, so the model can load before the first request; the app throttles it
    public var prewarm: () -> Void = {}
    /// writes a key change that the user confirmed in the pinned combo view; set by the app
    public var applyEdit: (KeyEdit) -> Void = { _ in }
    /// the app that had the focus when the chord field took it
    var editApp: NSRunningApplication?
    /// sees clicks in other apps while the combo view is pinned
    var outside: Any?
    /// true while the combo view is pinned; the panel width follows it. `$combo` sends in willSet, so the panel keeps its own copy.
    var wide = false
    var subs = Set<AnyCancellable>()

    public init(model: PanelModel, search: SearchModel, hotkeyLabel: String? = nil) {
        self.model = model; self.search = search
        panel = SanketaPanel(contentRect: NSRect(origin: .zero, size: Theme.panelSize),
                             styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                             backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(b)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        field.placeholderString = hotkeyLabel.map { "Search  \($0)" } ?? "Search"
        field.font = .systemFont(ofSize: 13.5, weight: .medium)
        field.focusRingType = .none
        field.delegate = self
        field.onClick = { [weak self] in self?.clicked() }
        panel.onKey = { [weak self] in self?.key($0) ?? false }
        panel.onKeyEquivalent = { [weak self] in self?.keyEquivalent($0) ?? false }
        panel.onMouseUp = { [weak self] in self?.mouseUp(at: $0.locationInWindow) }

        glass.cornerRadius = 18
        let host = NSHostingView(rootView: PanelView(model: model, search: search, field: field,
            grantAccessibility: { [weak self] in self?.grantAccessibility() },
            pick: { [weak self] in self?.pick($0) },
            clickLayer: { [weak self] in self?.clickLayer($0) },
            openFile: { [weak self] in self?.openFile($0) },
            makePack: { [weak self] in self?.makePack($0) },
            openResult: { [weak self] in self?.openResult($0) },
            record: { [weak self] in self?.startRecording() },
            applyEdit: { [weak self] in self?.confirmEdit() },
            cancelEdit: { [weak self] in self?.cancelEdit() }))
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass

        if let s = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: s.maxX - Theme.panelSize.width - 16, y: s.maxY - Theme.panelSize.height - 16,
                                  width: Theme.panelSize.width, height: Theme.panelSize.height), display: false)
        }
        panel.setFrameAutosaveName("SanketaPanel")
        setTranslucency(model.translucency)
        // each change, not only a change between list and combo: a frame from elsewhere must not stay
        model.$combo.combineLatest(model.$comboPinned).sink { [weak self] in self?.wide = $0 != nil && $1; self?.fit() }.store(in: &subs)
        model.$comboPinned.removeDuplicates().sink { [weak self] in self?.watchOutside($0) }.store(in: &subs)
    }

    var width: CGFloat { (wide ? Theme.comboSize : Theme.panelSize).width }

    /// Wide while the combo view is pinned, narrow else. The top-left corner stays, inside the screen's visible frame.
    func fit() {
        let f = panel.frame, w = width
        guard f.width != w else { return }
        var x = f.minX
        if let s = (panel.screen ?? NSScreen.main)?.visibleFrame { x = max(s.minX, min(x, s.maxX - w)) }
        panel.setFrame(NSRect(x: x, y: f.minY, width: w, height: f.height), display: panel.isVisible)
    }

    /// Low and Medium use regular glass under a strong adaptive tint; High is clear glass with a light tint.
    public func setTranslucency(_ t: Translucency) {
        model.translucency = t
        glass.style = t == .high ? .clear : .regular
    }

    public var isVisible: Bool { panel.isVisible }

    /// Shows without taking key or activating the app.
    public func show() {
        fit()
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    public func toggle() {
        if panel.isVisible { if searching { endSearch() }; panel.orderOut(nil); model.unpinCombo(); onDismiss() } else { show() }
    }

    public func beginSearch(previousApp: NSRunningApplication?) {
        searching = true
        model.listFocused = false
        self.previousApp = previousApp
        prewarm()
        show()
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    /// Clears the query and hands focus back to `previousApp`; AppKit resigns key. With `refocus` false, the panel
    /// resigns key but no app is made active, so the app that opens a vault result keeps the focus.
    public func endSearch(refocus: Bool = true) {
        let app = refocus ? previousApp : nil
        searching = false
        previousApp = nil
        search.clear()
        field.stringValue = ""
        model.listFocused = false
        handBack(to: app)
    }

    /// Gives the focus to `app`. A visible panel resigns key and stays in front; a hidden panel stays hidden. The Make a
    /// Pack window uses it too, when it closes.
    public func handBack(to app: NSRunningApplication?) {
        if panel.isVisible {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        app?.activate()
    }

    static var frontmostOther: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
    }

    /// Outside search, a click must never leave the panel key, or the user's next shortcut lands here. A click in the
    /// search field (its text, its field editor or its clear button) is a search click: it starts or keeps search, and
    /// focus stays. The field editor gets the mouse-down when the field already has focus, so `clicked` must come
    /// from here too, or the mouse-up would hand focus back. `point` is in window coordinates.
    func mouseUp(at point: NSPoint? = nil) {
        if let point, inField(point) { return clicked() }
        if point != nil { model.pinCombo() }
        // the chord field took the focus with this click, to read one key press
        guard model.editing?.recording != true, !searching, panel.isKeyWindow else { return }
        handBack(to: Self.frontmostOther)
    }

    func clickLayer(_ i: Int) {
        model.openLayer(at: i)
        mouseUp()
    }

    /// Tab from the field moves focus to the layer list.
    func focusList() {
        model.listFocused = true
        panel.makeFirstResponder(nil)
        if model.selectedLayer == nil { model.cycleLayer(1) }
    }

    func focusField() {
        model.listFocused = false
        panel.makeFirstResponder(field)
    }

    /// Keys while the layer list has focus: Tab/⇧Tab cycle sections (⇧Tab returns to the field in search),
    /// ↑/↓ cycle sections too, Esc ends search. Results are hidden then, so ↩ does nothing.
    func key(_ e: NSEvent) -> Bool {
        if model.editing?.recording == true { record(e); return true }
        let shift = e.modifierFlags.contains(.shift)
        switch Int(e.keyCode) {
        case kTab:
            if shift && searching { focusField() } else { model.cycleLayer(shift ? -1 : 1) }
        case kEscape:
            if searching { endSearch() } else {
                handBack(to: Self.frontmostOther)
                if model.comboPinned { unpin() } else { onDismiss() }
            }
        case kUp: model.listFocused ? model.cycleLayer(-1) : search.move(-1)
        case kDown: model.listFocused ? model.cycleLayer(1) : search.move(1)
        case kReturn: if !model.listFocused, let s = search.activate() { endSearch(refocus: s.open == nil) }
        default: return false
        }
        return true
    }

    /// ⌥Return: a resumed session's tmux window shows in the terminal, so the terminal gets the focus back; an opened file
    /// keeps the focus in its app.
    func alt() {
        switch search.activateAlt() {
        case .resumed: endSearch()
        case .opened: endSearch(refocus: false)
        case .none: NSSound.beep()
        }
    }

    /// In search, ⌘S saves the query in the vault, and ⇧⌘S saves the clipboard. ⌘D also saves the clipboard when it gets
    /// here: another app can own ⌘D as a global hotkey. ⌘E and ⇧⌘E change the scope; Tab already
    /// goes to the layer list. These keys are on the left hand. Every other ⌘ key goes on to the Edit menu (⌘A, ⌘C, ⌘X,
    /// ⌘V, ⌘Z, ⇧⌘Z) and the field editor.
    func keyEquivalent(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        if model.editing?.recording == true { record(e); return true }
        if let by = Self.scopeKey(keyCode: Int(e.keyCode), flags: e.modifierFlags, searching: searching) {
            search.cycleScope(by)
            return true
        }
        guard let clipboard = Self.saveKey(keyCode: Int(e.keyCode), flags: e.modifierFlags, searching: searching) else { return false }
        search.saveToVault(clipboard: clipboard)
        return true
    }

    /// The modifier keys of `flags`, without Caps Lock, the keypad and fn.
    nonisolated static func mods(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    }

    /// nil: not a save key. Else true for ⇧⌘S and ⌘D (the clipboard), false for ⌘S (the query).
    nonisolated static func saveKey(keyCode: Int, flags: NSEvent.ModifierFlags, searching: Bool) -> Bool? {
        guard searching else { return nil }
        switch (keyCode, mods(flags)) {
        case (kS, .command): return false
        case (kS, [.command, .shift]), (kD, .command): return true
        default: return nil
        }
    }

    /// nil: not a scope key. Else 1 for ⌘E (the next scope), -1 for ⇧⌘E (the previous scope).
    nonisolated static func scopeKey(keyCode: Int, flags: NSEvent.ModifierFlags, searching: Bool) -> Int? {
        guard searching, keyCode == kE else { return nil }
        return mods(flags) == .command ? 1 : mods(flags) == [.command, .shift] ? -1 : nil
    }

    /// True when `point` (window coordinates) is on the search field.
    func inField(_ point: NSPoint) -> Bool { field.bounds.contains(field.convert(point, from: nil)) }

    /// Clicking the field starts search without the hotkey; the terminal is still frontmost then. A second call for
    /// the same click (mouse-down, then mouse-up) does nothing.
    func clicked() {
        model.listFocused = false
        guard !searching else { return }
        model.unpinCombo()   // search takes the panel
        searching = true
        previousApp = Self.frontmostOther
        prewarm()
    }

    /// A click on a result opens it; search stays open, so its copy button can be used. Return copies and closes.
    func pick(_ i: Int) { search.click(i) }

    /// The open button of a vault result: it opens the result like Return, and the app that opens it keeps the focus.
    func openResult(_ i: Int) {
        search.select(i)
        if let s = search.activate() { endSearch(refocus: s.open == nil) }
    }

    public func controlTextDidChange(_ n: Notification) { search.query = field.stringValue }

    public func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): search.move(-1)
        case #selector(NSResponder.moveDown(_:)): search.move(1)
        case #selector(NSResponder.insertNewline(_:)): if let s = search.activate() { endSearch(refocus: s.open == nil) }
        // ⌥Return
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): alt()
        case #selector(NSResponder.cancelOperation(_:)): endSearch()
        case #selector(NSResponder.insertTab(_:)): focusList()
        case #selector(NSResponder.insertBacktab(_:)): break
        default: return false
        }
        return true
    }

    /// A drag changes only the height; the width follows the state.
    public func windowWillResize(_ sender: NSWindow, to size: NSSize) -> NSSize { NSSize(width: width, height: size.height) }

    /// A frame from elsewhere (the autosaved frame, a window manager, a screen change) gets the width of the state again.
    public func windowDidResize(_ n: Notification) { fit() }

    /// Clicking elsewhere ends search quietly. The field gives up its field editor, so the next click on it goes to the
    /// field itself and starts search again.
    public func windowDidResignKey(_ n: Notification) {
        if model.editing?.recording == true { model.editing?.recording = false; editApp = nil }
        guard searching else { return }
        panel.makeFirstResponder(nil)
        searching = false
        previousApp = nil
        search.clear()
        field.stringValue = ""
        model.listFocused = false
    }
}

// MARK: the pinned combo view

extension PanelController {
    /// The one time Sanketa reads a key press: the panel takes the focus for its chord field, until one chord or Esc.
    func startRecording() {
        guard model.editing != nil, !searching else { return }
        editApp = Self.frontmostOther
        model.editing?.new = nil
        model.editing?.warning = nil
        model.editing?.recording = true
        panel.makeKey()
        panel.makeFirstResponder(nil)
    }

    /// Esc with no modifier stops the edit; a modifier key alone waits for the key. Focus goes back after one chord that is taken.
    func record(_ e: NSEvent) {
        if Int(e.keyCode) == kEscape, Self.mods(e.modifierFlags).isEmpty { return cancelEdit() }
        // a chord that is not taken (the key now, or no modifier) shows why, and the field still reads
        guard let c = PanelModel.chord(keyCode: Int(e.keyCode), flags: e.modifierFlags), model.pick(c) else { return }
        endRecording()
    }

    /// Gives the focus back to the app that had it, when the chord field took it.
    func endRecording() {
        model.editing?.recording = false
        if panel.isKeyWindow { handBack(to: editApp) }
        editApp = nil
    }

    func cancelEdit() {
        model.cancelEdit()
        endRecording()
    }

    /// "Change" in the confirm step: the app writes the change; the view stays pinned.
    func confirmEdit() {
        guard let e = model.editing, e.new != nil, !e.blocked else { return }
        model.cancelEdit()
        endRecording()
        applyEdit(e)
    }

    /// Back to the layer view; the panel hides when it showed only for the combo.
    func unpin() {
        if model.unpinCombo(), !searching { panel.orderOut(nil) }
    }

    func watchOutside(_ on: Bool) {
        if let o = outside { NSEvent.removeMonitor(o); outside = nil }
        guard on else { return }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.unpin() }
        }
    }
}

let kTab = 48, kEscape = 53, kUp = 126, kDown = 125, kReturn = 36, kS = 1, kD = 2, kE = 14
