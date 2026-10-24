import AppKit
import SwiftUI
import SanketaCore
import SanketaSystem

/// Floating glass panel that only becomes key for hotkey-started search.
public final class SanketaPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onMouseUp: () -> Void = {}

    /// Keys reaching the window itself, i.e. while the layer list (not the field) has focus.
    public override func keyDown(with e: NSEvent) { if !onKey(e) { super.keyDown(with: e) } }

    public override func sendEvent(_ e: NSEvent) {
        super.sendEvent(e)
        if e.type == .leftMouseUp { onMouseUp() }
    }
}

@MainActor public final class PanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    public let panel: SanketaPanel
    public let field = SearchTextField()
    public let glass = NSGlassEffectView()
    /// the kolam mark at the start of the top row, before the breadcrumb; clicks pass through it
    let mark = PassthroughImageView()
    public let model: PanelModel
    public let search: SearchModel
    public private(set) var searching = false
    var previousApp: NSRunningApplication?
    public var grantAccessibility: () -> Void = {}
    /// opens a pack or config file for editing (a footer line)
    public var openFile: (String) -> Void = { _ in }
    /// makes a first pack for a program with none, then opens it
    public var makePack: (Layer) -> Void = { _ in }

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
        panel.onMouseUp = { [weak self] in self?.mouseUp() }

        glass.cornerRadius = 18
        mark.image = Brand.mark()
        mark.imageScaling = .scaleProportionallyUpOrDown
        // Theme.secondary in AppKit: label colour at 72 %
        mark.contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        mark.setAccessibilityElement(false)
        let host = NSHostingView(rootView: PanelView(model: model, search: search, field: field, mark: mark,
            grantAccessibility: { [weak self] in self?.grantAccessibility() },
            pick: { [weak self] in self?.pick($0) },
            clickLayer: { [weak self] in self?.clickLayer($0) },
            openFile: { [weak self] in self?.openFile($0) },
            makePack: { [weak self] in self?.makePack($0) }))
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
        show()
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    /// Clears the query and hands focus back to `previousApp`; AppKit resigns key.
    public func endSearch() {
        let app = previousApp
        searching = false
        previousApp = nil
        search.clear()
        field.stringValue = ""
        model.listFocused = false
        handBack(to: app)
    }

    func handBack(to app: NSRunningApplication?) {
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        app?.activate()
    }

    static var frontmostOther: NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
    }

    /// Outside search, a click must never leave the panel key, or the user's next shortcut lands here.
    func mouseUp() {
        guard !searching, panel.isKeyWindow else { return }
        handBack(to: Self.frontmostOther)
    }

    func clickLayer(_ i: Int) {
        model.selectLayer(at: i)
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
        case kReturn: if !model.listFocused, search.activate() != nil { endSearch() }
        default: return false
        }
        return true
    }

    /// Clicking the field starts search without the hotkey; the terminal is still frontmost then.
    func clicked() {
        model.listFocused = false
        guard !searching else { return }
        searching = true
        previousApp = Self.frontmostOther
    }

    func pick(_ i: Int) {
        search.select(i)
        if search.activate() != nil { endSearch() }
    }

    public func controlTextDidChange(_ n: Notification) { search.query = field.stringValue }

    public func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): search.move(-1)
        case #selector(NSResponder.moveDown(_:)): search.move(1)
        case #selector(NSResponder.insertNewline(_:)): if search.activate() != nil { endSearch() }
        case #selector(NSResponder.cancelOperation(_:)): endSearch()
        case #selector(NSResponder.insertTab(_:)): focusList()
        case #selector(NSResponder.insertBacktab(_:)): break
        default: return false
        }
        return true
    }

    /// Clicking elsewhere ends search quietly.
    public func windowDidResignKey(_ n: Notification) {
        guard searching else { return }
        searching = false
        previousApp = nil
        search.clear()
        field.stringValue = ""
        model.listFocused = false
    }
}

let kTab = 48, kEscape = 53, kUp = 126, kDown = 125, kReturn = 36
