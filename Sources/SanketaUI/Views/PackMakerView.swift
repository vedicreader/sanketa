import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SanketaCore

/// The Make a Pack window: the sources, the prompt and the ways to use it in a body that scrolls, then the check and the
/// preview. A fixed footer holds the status and the buttons, so Save never moves and the window never changes size.
struct PackMakerView: View {
    @ObservedObject var model: PackMakerModel
    let provider: String
    var chooseFile: () -> Void = {}

    static let pad: CGFloat = 20
    /// the body has a fixed width, so a scroll bar does not move it
    static let width = PackMakerWindow.size.width - 2 * pad
    static let footer: CGFloat = 60
    static let labelColumn: CGFloat = 58
    enum Anchor: Hashable { case paste, result }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sources
                        prompt
                        if model.showsPaste { paste.id(Anchor.paste) }
                        if model.outcome != nil { result.id(Anchor.result) }
                    }
                    .frame(width: Self.width, alignment: .leading)
                    .padding(.horizontal, Self.pad).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.showsPaste) { _, on in if on { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Anchor.paste, anchor: .bottom) } } }
                .onChange(of: model.outcome) { _, o in if o != nil { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Anchor.result, anchor: .top) } } }
            }
            footer
        }
        .frame(width: PackMakerWindow.size.width, height: PackMakerWindow.size.height)
    }

    // MARK: body

    @ViewBuilder var sources: some View {
        section("Sources") {
            editor($model.urls, PackMakerModel.urlsPlaceholder, height: 52)
        }
        if model.showsDocs {
            // the panel's link style: underlined, muted, no accent colour
            section("Docs text", trailing: Button(action: chooseFile) { Text("Choose a File…").underline() }
                .buttonStyle(.plain).font(Theme.small).foregroundStyle(Theme.secondary)) {
                editor($model.docs, PackMakerModel.docsPlaceholder, height: 96)
                if model.docsCut { note(PackMakerModel.docsCutText) }
            }
        }
    }

    var prompt: some View {
        section("Prompt") {
            ScrollView {
                Text(model.prompt).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.primary.opacity(0.85))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
            }
            .frame(height: 150).fieldFill()
            note(model.contents)
            HStack(spacing: 8) {
                ForEach(model.actions, id: \.self) { a in
                    Button { model.send(a) } label: { actionLabel(a) }
                        .disabled(a != .copy && !model.canSend(a))
                        .help(model.help(a) ?? "")
                        .defaultAction(model.primary == .send(a))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    /// "Copied" takes the place of "Copy Prompt" at the same width, so the next buttons do not move.
    @ViewBuilder func actionLabel(_ a: PackMaker.Action) -> some View {
        let text = PackMakerModel.label(a, provider: provider)
        if a == .copy {
            ZStack { Text(text).hidden(); Text(model.copied ? "Copied" : text) }
        } else {
            Text(text)
        }
    }

    var paste: some View {
        section("Result") {
            editor($model.pasted, PackMakerModel.pastePlaceholder, height: 110)
            HStack {
                Spacer()
                Button("Check") { model.check() }
                    .disabled(model.pasted.isEmpty || model.busy != nil)
                    .defaultAction(model.primary == .check)
            }
        }
    }

    var result: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.notes.isEmpty {
                section("Check") {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { _, n in noteRow(n) }
                }
            }
            if let p = model.preview { preview(p) }
        }
    }

    func noteRow(_ n: PackMakerModel.Note) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n.kind == .error ? "Error" : n.kind == .warning ? "Warning" : "Fixed").font(Theme.header)
                .foregroundStyle(Theme.secondary).frame(width: Self.labelColumn, alignment: .leading)
            Text(n.text).font(Theme.small).foregroundStyle(n.kind == .fix ? Theme.secondary : Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The pack as the panel shows it: the groups with their keys, then the tips, and what a save changes.
    func preview(_ p: Pack) -> some View {
        section("Preview") {
            if let d = model.diff {
                note("New keys: \(d.added.count). Changed keys: \(d.changed.count). Removed keys: \(d.removed.count).")
            }
            VStack(alignment: .leading, spacing: Theme.rowGap) {
                ForEach(PanelModel.groups(p.keys)) { g in
                    if let n = g.name { Text(n).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 6) }
                    ForEach(Array(g.keys.enumerated()), id: \.offset) { _, k in
                        HStack(alignment: .firstTextBaseline) {
                            Text(k.action).font(Theme.text)
                            Spacer(minLength: 10)
                            KeyChip(keys: k.keys)
                        }
                    }
                }
                if !p.tips.isEmpty { Text("Tips").font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 6) }
                ForEach(Array(p.tips.enumerated()), id: \.offset) { _, t in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.title).font(Theme.text)
                        Text(t.snippet).font(Theme.snippet).foregroundStyle(Theme.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: footer

    var footer: some View {
        HStack(spacing: 12) {
            status.frame(maxWidth: .infinity, alignment: .leading)
            Button(model.busy == nil ? "Cancel" : "Stop") { model.cancel() }.keyboardShortcut(.cancelAction)
            if model.busy == nil, let o = model.outcome {
                if o.canSave {
                    Button("Save") { model.save() }.defaultAction(model.primary == .save)
                } else if model.canAskAgain {
                    Button("Ask Again") { model.askAgain() }.defaultAction(model.primary == .askAgain)
                } else {
                    Button("Save as Draft") { model.saveDraft() }.defaultAction(model.primary == .saveDraft)
                }
            }
        }
        .padding(.horizontal, Self.pad)
        .frame(height: Self.footer)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// The status, with a spinner and the elapsed time while a request runs.
    var status: some View {
        HStack(alignment: .center, spacing: 8) {
            if let since = model.busySince {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: since, by: 1)) { c in
                    Text(PackMakerModel.elapsed(c.date.timeIntervalSince(since))).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            }
            Text(statusText).font(Theme.small).foregroundStyle(model.busy == nil ? Theme.primary : Theme.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    var statusText: String {
        if model.status.isEmpty, let p = model.preview, model.outcome?.canSave == true { return PackMakerModel.ready(keys: p.keys.count, tips: p.tips.count) }
        return model.status
    }

    // MARK: parts

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        section(title, trailing: EmptyView(), content)
    }

    func section<T: View, C: View>(_ title: String, trailing: T, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.header).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                trailing
            }
            content()
        }
    }

    func note(_ s: String) -> some View {
        Text(s).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }

    func editor(_ text: Binding<String>, _ placeholder: String, height: CGFloat) -> some View {
        PlainEditor(text: text, placeholder: placeholder, commandReturn: { model.performPrimary() }, escape: { model.cancel() })
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: PlainEditor.fontSize)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, PlainEditor.inset.width).padding(.vertical, PlainEditor.inset.height).allowsHitTesting(false)
                }
            }
            .fieldFill()
    }
}

extension View {
    /// The quiet fill of a text area: no border, the same for the fields and the prompt.
    func fieldFill() -> some View { background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)) }

    /// Return clicks this button. Only one button in the window has it at a time.
    @ViewBuilder func defaultAction(_ on: Bool) -> some View {
        if on { keyboardShortcut(.defaultAction) } else { self }
    }
}

/// A plain text area. Tab and ⇧Tab move to the next or previous control, Return makes a new line, ⌘Return does the
/// default action of the window, and Esc cancels.
struct PlainEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var commandReturn: () -> Void = {}
    var escape: () -> Void = {}
    static let fontSize: CGFloat = 13
    static let inset = CGSize(width: 8, height: 7)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainEditor
        init(_ p: PlainEditor) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = EditorTextView(frame: .zero)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: Self.fontSize)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = Self.inset
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.setAccessibilityLabel(placeholder)
        tv.string = text
        tv.delegate = context.coordinator
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.documentView = tv
        update(tv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? EditorTextView else { return }
        if tv.string != text { tv.string = text }
        update(tv)
    }

    func update(_ tv: EditorTextView) {
        tv.commandReturn = commandReturn
        tv.escape = escape
    }
}

/// The text view of `PlainEditor`.
final class EditorTextView: NSTextView {
    var commandReturn: () -> Void = {}
    var escape: () -> Void = {}

    static func isCommandReturn(_ e: NSEvent) -> Bool {
        (Int(e.keyCode) == kReturn || Int(e.keyCode) == kEnter) && e.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
    override func cancelOperation(_ sender: Any?) { escape() }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, Self.isCommandReturn(e) else { return super.performKeyEquivalent(with: e) }
        commandReturn()
        return true
    }

    override func keyDown(with e: NSEvent) {
        if Self.isCommandReturn(e) { return commandReturn() }
        super.keyDown(with: e)
    }
}

/// Plain Return in a text area makes a new line: the default button does not take it. Other keys go to SwiftUI.
final class PackMakerHostingView<Content: View>: NSHostingView<Content> {
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder is EditorTextView, Int(e.keyCode) == kReturn,
           e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { return false }
        return super.performKeyEquivalent(with: e)
    }
}

let kEnter = 76

/// The window for one app. It takes the focus when it opens, because the user types in it. Each close (Esc, Cancel,
/// the close button, or a save) stops a request that runs and calls `onClose`, which gives the focus back.
@MainActor public final class PackMakerWindow: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public let model: PackMakerModel
    public var onClose: () -> Void = {}
    static let size = CGSize(width: 560, height: 700)

    public init(model: PackMakerModel, provider: String) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = PackMakerModel.title(model.app.name)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = PackMakerHostingView(rootView: PackMakerView(model: model, provider: provider,
                                                                          chooseFile: { [weak self] in self?.chooseFile() }))
        model.requestClose = { [weak self] in self?.window.close() }
    }

    public func show() {
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose()
    }

    /// A text or HTML file that the user chooses goes into the docs text, as plain text.
    func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .html, .text]
        p.allowsMultipleSelection = false
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            // a file above the limit is not read into memory as text
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= PackMaker.maxText, let s = try? String(contentsOf: u, encoding: .utf8) else { self?.model.useFile(nil); return }
            self?.model.useFile(s)
        }
    }

    /// The question before a save replaces a file.
    public static func confirmReplace(_ f: URL) -> Bool {
        let a = NSAlert()
        a.messageText = "Replace \(f.lastPathComponent)?"
        a.informativeText = "Sanketa copies the old file to a .bak file first."
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
