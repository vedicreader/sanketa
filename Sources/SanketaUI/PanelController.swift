import AppKit
import SwiftUI
import SanketaCore
import SanketaSystem

/// Floating glass panel that only becomes key for hotkey-started search.
public final class SanketaPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
}

@MainActor public final class PanelController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    public let panel: SanketaPanel
    public let field = SearchTextField()
    public let model: PanelModel
    public let search: SearchModel
    public private(set) var searching = false
    var previousApp: NSRunningApplication?
    public var grantAccessibility: () -> Void = {}

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

        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.style = .clear
        let host = NSHostingView(rootView: PanelView(model: model, search: search, field: field,
            grantAccessibility: { [weak self] in self?.grantAccessibility() },
            pick: { [weak self] in self?.pick($0) }))
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass

        if let s = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: s.maxX - Theme.panelSize.width - 16, y: s.maxY - Theme.panelSize.height - 16,
                                  width: Theme.panelSize.width, height: Theme.panelSize.height), display: false)
        }
        panel.setFrameAutosaveName("SanketaPanel")
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
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        app?.activate()
    }

    /// Clicking the field starts search without the hotkey; the terminal is still frontmost then.
    func clicked() {
        guard !searching else { return }
        searching = true
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
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
    }
}
