import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SanketaCore

/// The Make a Pack window: sources, the prompt, the buttons, the answer, the preview and Save.
struct PackMakerView: View {
    @ObservedObject var model: PackMakerModel
    let provider: String
    var chooseFile: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                heading("Sources")
                editor($model.urls, PackMakerModel.urlsPlaceholder, height: 48)
                if model.showsDocs {
                    heading("Docs text")
                    editor($model.docs, PackMakerModel.docsPlaceholder, height: 90)
                    HStack {
                        Button("Choose a File…", action: chooseFile)
                        if model.docsCut { note(PackMakerModel.docsCutText) }
                    }
                }
                heading("Prompt")
                ScrollView {
                    Text(model.prompt).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                .frame(height: 170)
                .background(Color.primary.opacity(0.04))
                note(model.contents)
                buttons
                if model.showsPaste {
                    heading("Result")
                    editor($model.pasted, PackMakerModel.pastePlaceholder, height: 90)
                    Button("Check") { model.check() }.disabled(model.pasted.isEmpty || model.busy != nil)
                }
                if !model.status.isEmpty { Text(model.status).font(Theme.text).fixedSize(horizontal: false, vertical: true) }
                ForEach(Array(model.notes.enumerated()), id: \.offset) { _, n in note(n) }
                if model.canAskAgain { Button("Ask Again with the Errors") { model.askAgain() } }
                if let p = model.preview { preview(p) }
                saveButtons
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    var buttons: some View {
        HStack {
            ForEach(model.actions, id: \.self) { a in
                Button(a == .copy && model.copied ? "Copied" : PackMakerModel.label(a, provider: provider)) { model.send(a) }
                    .disabled(a != .copy && !model.canSend(a))
                    .help(model.help(a) ?? "")
            }
            if model.busy != nil {
                ProgressView().controlSize(.small)
                Button("Stop") { model.stop() }
            }
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder var saveButtons: some View {
        if let o = model.outcome {
            HStack {
                Spacer()
                if !o.canSave && !model.canAskAgain { Button("Save as Draft") { model.saveDraft() }.disabled(model.busy != nil) }
                if o.canSave { Button("Save") { model.save() }.keyboardShortcut(.defaultAction).disabled(!model.canSave) }
            }
        }
    }

    /// The pack as the panel shows it: the groups with their keys, then the tips, and what a save changes.
    func preview(_ p: Pack) -> some View {
        VStack(alignment: .leading, spacing: Theme.rowGap) {
            heading("Preview")
            if let d = model.diff {
                note("New keys: \(d.added.count). Changed keys: \(d.changed.count). Removed keys: \(d.removed.count).")
            }
            ForEach(PanelModel.groups(p.keys)) { g in
                if let n = g.name { Text(n).font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 4) }
                ForEach(Array(g.keys.enumerated()), id: \.offset) { _, k in
                    HStack(alignment: .firstTextBaseline) {
                        Text(k.action).font(Theme.text)
                        Spacer(minLength: 10)
                        KeyChip(keys: k.keys)
                    }
                }
            }
            if !p.tips.isEmpty { Text("Tips").font(Theme.small).foregroundStyle(Theme.secondary).padding(.top, 4) }
            ForEach(Array(p.tips.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(Theme.text)
                    Text(t.snippet).font(Theme.snippet).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }
        }
    }

    func heading(_ s: String) -> some View { Text(s).font(Theme.header).foregroundStyle(Theme.secondary) }

    func note(_ s: String) -> some View {
        Text(s).font(Theme.small).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }

    func editor(_ text: Binding<String>, _ placeholder: String, height: CGFloat) -> some View {
        TextEditor(text: text).font(.system(size: 12.5)).frame(height: height)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
    }
}

/// The window for one app. It takes the focus when it opens, because the user types in it. Closing it stops a
/// request that runs.
@MainActor public final class PackMakerWindow: NSObject, NSWindowDelegate {
    public let window: NSWindow
    public let model: PackMakerModel
    public var onClose: () -> Void = {}

    public init(model: PackMakerModel, provider: String) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = PackMakerModel.title(model.app.name)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PackMakerView(model: model, provider: provider,
                                                                   chooseFile: { [weak self] in self?.chooseFile() },
                                                                   close: { [weak self] in self?.window.close() }))
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
