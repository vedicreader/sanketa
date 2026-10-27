import AppKit
import Combine
import os
import SwiftUI
import SanketaCore

/// The bar never takes the focus, the mouse or a place in the window cycle.
final class AeroBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A thin glass strip at the top center of the screen under the mouse, just under the menu bar: the AeroSpace keys of
/// the held combo or of the mode. Clicks go through it. It hides when the combo view is pinned.
@MainActor public final class AeroBarController {
    let panel: AeroBarPanel
    let glass = NSGlassEffectView()
    let host: NSHostingView<AeroBarView>
    let model: PanelModel
    /// the bar that shows now; nil while hidden
    public private(set) var bar: AeroBar?
    var subs = Set<AnyCancellable>()
    /// the space between the menu bar and the bar
    public static let gap: CGFloat = 6
    /// read with: log stream --predicate 'subsystem == "dev.sanketa"'
    public static let log = Logger(subsystem: "dev.sanketa", category: "bar")

    public init(model: PanelModel) {
        self.model = model
        panel = AeroBarPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 32), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        host = NSHostingView(rootView: AeroBarView(bar: nil, maxWidth: 1000, translucency: model.translucency))
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        host.sizingOptions = []
        glass.contentView = host
        panel.contentView = glass
        setTranslucency(model.translucency)
        // the panel's translucency setting; the pinned view edits keys, so the bar goes
        model.$translucency.removeDuplicates().sink { [weak self] in self?.setTranslucency($0) }.store(in: &subs)
        model.$comboPinned.removeDuplicates().sink { [weak self] in if $0 { self?.hide() } }.store(in: &subs)
    }

    public var isVisible: Bool { panel.isVisible }

    /// The same glass style as the panel: Low and Medium regular glass, High clear glass.
    func setTranslucency(_ t: Translucency) {
        glass.style = t == .high ? .clear : .regular
        if let b = bar { host.rootView = AeroBarView(bar: b, maxWidth: host.rootView.maxWidth, translucency: t) }
    }

    /// Shows `bar`, or hides for nil, without the focus. A pinned combo view keeps the bar hidden.
    public func show(_ bar: AeroBar?) {
        guard let bar else { Self.log.debug("bar skip: no AeroSpace keys for this combo"); return hide() }
        guard !model.comboPinned else { Self.log.debug("bar skip: the combo view is pinned"); return hide() }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let maxWidth = (vf.width * AeroBar.maxShare).rounded(.down)
        host.rootView = AeroBarView(bar: bar, maxWidth: maxWidth, translucency: model.translucency)
        let size = Self.fitting(host)
        guard size.width > 0, size.height > 0 else { Self.log.error("bar skip: the bar measures \(size.width, privacy: .public)x\(size.height, privacy: .public)"); return hide() }
        self.bar = bar
        glass.cornerRadius = min(size.height / 2, 16)
        let f = Self.frame(size: size, visible: vf)
        panel.setFrame(f, display: false)
        panel.orderFrontRegardless()
        Self.log.debug("bar show: \(bar.items.count, privacy: .public) items at \(f.debugDescription, privacy: .public)")
    }

    public func hide() {
        bar = nil
        panel.orderOut(nil)
    }

    /// Top center of `visible`, `gap` under its top edge.
    nonisolated static func frame(size: CGSize, visible vf: NSRect) -> NSRect {
        NSRect(x: (vf.midX - size.width / 2).rounded(), y: vf.maxY - gap - size.height, width: size.width, height: size.height)
    }

    /// The size the view asks for. Not `fittingSize`: with no `sizingOptions` the host has no constraints, so that is zero.
    static func fitting(_ host: NSHostingView<AeroBarView>) -> CGSize {
        let s = NSHostingController(rootView: host.rootView).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }
}

/// One line (or two) of "key word" pairs with wide gaps, then a muted "· AeroSpace". No boxes, no pills.
struct AeroBarView: View {
    let bar: AeroBar?
    let maxWidth: CGFloat
    let translucency: Translucency
    @Environment(\.colorScheme) var scheme
    static let gap: CGFloat = 18

    var body: some View {
        BarFlow(gap: Self.gap, lineGap: 6, maxWidth: maxWidth) {
            if let bar {
                if let l = bar.lead { Text(l).font(Theme.small).foregroundStyle(Theme.secondary) }
                ForEach(Array(bar.items.enumerated()), id: \.offset) { _, i in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        KeyLabel(text: i.keys).foregroundStyle(Theme.primary)
                        Text(i.word).font(Theme.small).foregroundStyle(Theme.secondary)
                    }
                    .fixedSize()
                }
                Text(AeroBar.tail).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .fixedSize()
        .background(Theme.tint(scheme == .dark).opacity(Theme.tintOpacity(translucency)))
        .accessibilityElement(children: .combine)
    }
}

/// Lays its views out left to right and starts a new line when the next view does not fit in `maxWidth`
/// (`AeroBar.wrap`). Each line is centered on the widest.
struct BarFlow: Layout {
    let gap: CGFloat
    let lineGap: CGFloat
    let maxWidth: CGFloat

    func lines(_ subviews: Subviews) -> (lines: [[Int]], sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return (AeroBar.wrap(sizes.map { Double($0.width) }, gap: Double(gap), max: Double(maxWidth)), sizes)
    }

    func lineWidth(_ l: [Int], _ sizes: [CGSize]) -> CGFloat { l.map { sizes[$0].width }.reduce(0, +) + gap * CGFloat(max(l.count - 1, 0)) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (ls, sizes) = lines(subviews)
        let w = ls.map { lineWidth($0, sizes) }.max() ?? 0
        let h = ls.map { l in l.map { sizes[$0].height }.max() ?? 0 }.reduce(0, +) + lineGap * CGFloat(max(ls.count - 1, 0))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (ls, sizes) = lines(subviews)
        var y = bounds.minY
        for l in ls {
            let h = l.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX + (bounds.width - lineWidth(l, sizes)) / 2
            for i in l {
                // each view sits on the line's baseline
                let base = subviews[i].dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline]
                let lineBase = l.map { subviews[$0].dimensions(in: .unspecified)[VerticalAlignment.firstTextBaseline] }.max() ?? base
                subviews[i].place(at: CGPoint(x: x, y: y + lineBase - base), proposal: .unspecified)
                x += sizes[i].width + gap
            }
            y += h + lineGap
        }
    }
}
