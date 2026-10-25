import AppKit
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
    var previousApp: NSRunningApplication?
    public var grantAccessibility: () -> Void = {}
    /// opens a pack or config file for editing (a footer line)
    public var openFile: (String) -> Void = { _ in }
    /// makes a first pack for a program with none, then opens it
    public var makePack: (Layer) -> Void = { _ in }
    /// called when search starts, so the model can load before the first request; the app throttles it
    public var prewarm: () -> Void = {}

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
            openResult: { [weak self] in self?.openResult($0) }))
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass

        if let s = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: s.maxX - Theme.panelSize.width - 16, y: s.maxY - Theme.panelSize.height - 16,
                                  width: Theme.panelSize.width, height: Theme.panelSize.height), display: false)
        }
        panel.setFrameAutosaveName("SanketaPanel")
        setTranslucency(model.translucency)
    }

    /// Low and Medium use regular glass under a strong adaptive tint; High is clear glass with a light tint.
    public func setTranslucency(_ t: Translucency) {
        model.translucency = t
        glass.style = t == .high ? .clear : .regular
    }

    public var isVisible: Bool { panel.isVisible }

    /// Shows without taking key or activating the app.
    public func show() {
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    public func toggle() {
        if panel.isVisible { if searching { endSearch() }; panel.orderOut(nil) } else { show() }
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
        guard !searching, panel.isKeyWindow else { return }
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
        let shift = e.modifierFlags.contains(.shift)
        switch Int(e.keyCode) {
        case kTab:
            if shift && searching { focusField() } else { model.cycleLayer(shift ? -1 : 1) }
        case kEscape: searching ? endSearch() : handBack(to: Self.frontmostOther)
        case kUp: model.listFocused ? model.cycleLayer(-1) : search.move(-1)
        case kDown: model.listFocused ? model.cycleLayer(1) : search.move(1)
        case kReturn: if !model.listFocused, let s = search.activate() { endSearch(refocus: s.open == nil) }
        default: return false
        }
        return true
    }

    /// In search, ⌘S saves the query in the vault and ⌘D saves the clipboard. Both keys are on the left hand.
    func keyEquivalent(_ e: NSEvent) -> Bool {
        guard searching, e.type == .keyDown, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch Int(e.keyCode) {
        case kS: search.saveToVault(clipboard: false)
        case kD: search.saveToVault(clipboard: true)
        default: return false
        }
        return true
    }

    /// True when `point` (window coordinates) is on the search field.
    func inField(_ point: NSPoint) -> Bool { field.bounds.contains(field.convert(point, from: nil)) }

    /// Clicking the field starts search without the hotkey; the terminal is still frontmost then. A second call for
    /// the same click (mouse-down, then mouse-up) does nothing.
    func clicked() {
        model.listFocused = false
        guard !searching else { return }
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
        case #selector(NSResponder.cancelOperation(_:)): endSearch()
        case #selector(NSResponder.insertTab(_:)): focusList()
        case #selector(NSResponder.insertBacktab(_:)): break
        default: return false
        }
        return true
    }

    /// Clicking elsewhere ends search quietly. The field gives up its field editor, so the next click on it goes to the
    /// field itself and starts search again.
    public func windowDidResignKey(_ n: Notification) {
        guard searching else { return }
        panel.makeFirstResponder(nil)
        searching = false
        previousApp = nil
        search.clear()
        field.stringValue = ""
        model.listFocused = false
    }
}

let kTab = 48, kEscape = 53, kUp = 126, kDown = 125, kReturn = 36, kS = 1, kD = 2
