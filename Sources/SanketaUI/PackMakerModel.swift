import AppKit
import Foundation
import SanketaCore

/// What the Make a Pack window does: the prompt, the three ways to use it, the steps for the answer, the preview and
/// the save. The app gives the outside world (the models, the packs folder, the pasteboard, the replace question);
/// tests give fakes. The prompt holds no window title, file name or path, and no prompt or answer is logged.
@MainActor public final class PackMakerModel: ObservableObject {
    public struct World {
        public var app: PackMaker.App
        /// all the menu shortcuts of the app; the prompt gets them after the privacy filter
        public var menu: [MenuShortcut]
        /// the TOML of the bundled pack for the app; the prompt gets it only when the user has no pack
        public var existing: String?
        /// the user's pack file for the app; the prompt gets its keys and tips with no comments, and Save writes it
        public var userPack: URL?
        public var config: LLMConfig
        /// "OpenAI", or the host of another server
        public var provider: String
        /// an on-device model is downloaded and this build can run it
        public var onDeviceReady: Bool
        public var sendOpenAI: ((String) async throws -> String)?
        public var sendOnDevice: ((String) async throws -> String)?
        public var packsDir: URL
        public var pasteboard: NSPasteboard
        /// asks the user before a file is replaced; true to replace it
        public var confirmReplace: (URL) -> Bool
        /// called after a save, with the file
        public var saved: (URL) -> Void
        /// shows what a save or a draft save did, or why it did not, in the panel's toast
        public var toast: (String) -> Void

        public init(app: PackMaker.App, menu: [MenuShortcut], existing: String?, userPack: URL? = nil, config: LLMConfig, provider: String,
                    onDeviceReady: Bool,
                    sendOpenAI: ((String) async throws -> String)?, sendOnDevice: ((String) async throws -> String)?,
                    packsDir: URL, pasteboard: NSPasteboard = .general, confirmReplace: @escaping (URL) -> Bool, saved: @escaping (URL) -> Void,
                    toast: @escaping (String) -> Void = { _ in }) {
            self.app = app; self.menu = menu; self.existing = existing; self.userPack = userPack; self.config = config; self.provider = provider
            self.onDeviceReady = onDeviceReady; self.sendOpenAI = sendOpenAI; self.sendOnDevice = sendOnDevice; self.packsDir = packsDir
            self.pasteboard = pasteboard; self.confirmReplace = confirmReplace; self.saved = saved; self.toast = toast
        }
    }

    let world: World
    /// the pack text for the prompt: the user pack, else the bundled pack, with allow-listed fields and no comments
    let context: String?
    /// the docs URLs that the user types, one on each line
    @Published public var urls = "" { didSet { prompt = Self.promptA(world, context, urls) } }
    /// the docs text for the on-device model
    @Published public var docs = ""
    /// the answer of a local agent, pasted by the user
    @Published public var pasted = ""
    /// variant A, as the user sees it and as Copy Prompt and Send to OpenAI use it
    @Published public private(set) var prompt: String
    @Published public private(set) var status = ""
    /// the request that runs; Stop ends it
    @Published public private(set) var busy: PackMaker.Action?
    @Published public private(set) var copied = false
    @Published public private(set) var showsPaste = false
    @Published public private(set) var outcome: PackMaker.Outcome?
    /// A line of the check: a fix that Sanketa made, or a lint error or warning.
    public struct Note: Equatable {
        public enum Kind { case fix, warning, error }
        public var kind: Kind
        public var text: String
        public init(_ kind: Kind, _ text: String) { self.kind = kind; self.text = text }
    }

    /// The main action of the step, which Return does.
    public enum Primary: Equatable { case send(PackMaker.Action), check, askAgain, save, saveDraft }

    /// the lines of the check: style fixes, removed menu copies, lint errors and warnings
    @Published public private(set) var notes: [Note] = []
    /// when the request that runs started, for the elapsed time
    @Published public private(set) var busySince: Date?
    @Published public private(set) var preview: Pack?
    @Published public private(set) var diff: PackMaker.Diff?
    @Published public private(set) var savedFile: URL?
    /// the request that runs, so tests can wait for it
    public private(set) var work: Task<Void, Never>?
    /// where the last answer came from, and how many times the model got the errors back
    var source: PackMaker.Action?
    var retries = 0
    /// closes the window; the window gives the focus back to the app that was in front
    public var requestClose: () -> Void = {}

    public init(_ world: World) {
        self.world = world
        let text = world.userPack.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? world.existing
        context = text.flatMap { PackMaker.promptPack($0, app: world.app) }
        prompt = Self.promptA(world, context, "")
    }

    static func promptA(_ w: World, _ context: String?, _ urls: String) -> String {
        PackMaker.promptA(app: w.app, menu: w.menu, existing: context, urls: PackMaker.urls(urls))
    }

    public var app: PackMaker.App { world.app }
    public var actions: [PackMaker.Action] { PackMaker.actions(world.config, onDeviceReady: world.onDeviceReady) }
    public var contents: String { PackMaker.contents(menuCount: PackMaker.menuLines(world.menu).count, userPack: world.userPack != nil) }
    public var docsCut: Bool { PackMaker.fitDocs(docs).cut }
    public var showsDocs: Bool { actions.contains(.onDevice) }

    // MARK: text

    public static func title(_ app: String) -> String { "Make a Pack for \(app)" }
    public static let urlsPlaceholder = "Docs URLs, one on each line (optional)"
    public static let docsPlaceholder = "Paste the shortcut page here. The on-device model cannot read web pages."
    public static let pastePlaceholder = "Paste the result here"
    public static let copiedText = "Copied. Paste the prompt in your agent. Then paste the result below."
    public static let notReady = "The on-device model is not ready. Choose a model in the menu."
    public static let docsCutText = "Sanketa uses the first 4,000 characters of shortcut lines. Paste a shorter page for a better result."
    public static let notAPack = "The answer is not a pack. Ask again, or use Copy Prompt with a stronger model."
    public static let pasteDocsFirst = "Paste the docs text first."
    public static let stopped = "Stopped."
    public static let pasteFix = "Fix the errors in the text, then click Check."

    public static func label(_ a: PackMaker.Action, provider: String) -> String {
        switch a {
        case .copy: "Copy Prompt"
        case .openAI: provider == "OpenAI" ? "Send to OpenAI" : "Send to \(provider)"
        case .onDevice: "Send to On-Device Model"
        }
    }

    public static func sending(_ a: PackMaker.Action, provider: String) -> String {
        if a == .onDevice { return "The on-device model is writing the pack. This can take 2 minutes." }
        return provider == "OpenAI" ? "OpenAI is reading the docs. This can take 2 minutes."
            : "\(provider) is writing the pack. It cannot read web pages, so it uses only the prompt."
    }

    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    public static func errors(_ n: Int) -> String { "The pack has \(count(n, "error")). Sanketa can ask the model to fix them." }
    public static func stillErrors(_ n: Int) -> String { "The pack still has \(count(n, "error")). Save it as a draft, or edit it." }
    public static func styleFixes(_ n: Int) -> String { "Sanketa changed \(count(n, "key")) to the Mac key style." }
    public static func menuCopies(_ n: Int) -> String { "Sanketa removed \(count(n, "key")) that the menus already show." }
    public static func saved(_ file: String, app: String) -> String { "Saved \(file). The keys show when \(app) is in front." }
    public static func saveFailed(_ why: String) -> String { "Sanketa cannot write the file: \(why)." }
    public static func ready(keys: Int, tips: Int) -> String { "The pack is ready: \(count(keys, "key")) and \(count(tips, "tip"))." }
    /// The time that a request runs, as m:ss.
    public static func elapsed(_ t: TimeInterval) -> String { let s = max(0, Int(t)); return String(format: "%d:%02d", s / 60, s % 60) }

    /// The text for a request that failed.
    public static func failure(_ e: Error, provider: String) -> String {
        if (e as? ChoiceError) == .noKey { return StatusMenus.noKey(provider: provider) + " in the menu." }
        if (e as? URLError)?.code == .timedOut { return "\(provider) did not answer in 3 minutes. Try again, or use Copy Prompt." }
        let why: String = switch e {
        case ChoiceError.http(let c): c >= 500 ? "server error \(c)" : c == 401 ? "the key is not correct" : c == 429 ? "too many requests" : "error \(c)"
        case ChoiceError.notAllowed: "the server address must start with https://"
        case ChoiceError.badResponse: "the answer has no text"
        case let u as URLError: u.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        default: "an error occurred"
        }
        return "\(provider) did not answer: \(why). Try again, or use Copy Prompt."
    }

    // MARK: actions

    public func canSend(_ a: PackMaker.Action) -> Bool {
        guard busy == nil else { return false }
        return a != .onDevice || !docs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Help text for a button that is off.
    public func help(_ a: PackMaker.Action) -> String? { a == .onDevice && !canSend(a) && busy == nil ? Self.pasteDocsFirst : nil }

    /// Copies variant A. The button says "Copied" for 2 seconds, and the paste area opens.
    public func copyPrompt() {
        world.pasteboard.clearContents()
        world.pasteboard.setString(prompt, forType: .string)
        copied = true
        showsPaste = true
        status = Self.copiedText
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.copied = false }
    }

    /// Sends variant A to OpenAI, or variant B with the docs text to the on-device model.
    public func send(_ a: PackMaker.Action) {
        switch a {
        case .copy: copyPrompt()
        case .openAI: run(.openAI, prompt)
        case .onDevice:
            guard canSend(.onDevice) else { status = Self.pasteDocsFirst; return }
            run(.onDevice, PackMaker.promptB(app: world.app, menu: world.menu, docs: docs, json: true))
        }
        retries = 0
    }

    /// A text or HTML file for the docs text; false (and "not a pack") when it is too large or nil (not readable).
    @discardableResult public func useFile(_ text: String?) -> Bool {
        guard let text, text.utf8.count <= PackMaker.maxText else { status = Self.notAPack; return false }
        docs = PackMaker.plainText(html: text)
        return true
    }

    /// Save works only for a pack with no errors, and not while a request runs.
    public var canSave: Bool { busy == nil && outcome?.canSave == true }

    /// Ends the request that runs.
    public func stop() {
        work?.cancel()
    }

    /// Esc and Cancel: stop the request that runs, else close the window.
    public func cancel() {
        if busy != nil { stop() } else { requestClose() }
    }

    public var primary: Primary? {
        guard busy == nil else { return nil }
        if let o = outcome {
            if o.canSave { return .save }
            if canAskAgain { return .askAgain }
            return source == .copy ? .check : .saveDraft
        }
        if showsPaste && !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .check }
        if actions.contains(.openAI) { return .send(.openAI) }
        if actions.contains(.onDevice) && canSend(.onDevice) { return .send(.onDevice) }
        return .send(.copy)
    }

    /// Return in the window, and ⌘Return in a text area.
    public func performPrimary() {
        switch primary {
        case .send(let a): send(a)
        case .check: check()
        case .askAgain: askAgain()
        case .save: save()
        case .saveDraft: saveDraft()
        case nil: break
        }
    }

    /// The pasted answer of a local agent goes through the same steps.
    public func check() {
        source = .copy
        take(pasted)
    }

    /// The model gets the TOML and the lint errors back, one time.
    public var canAskAgain: Bool {
        guard let o = outcome, !o.canSave, busy == nil, retries == 0, let s = source else { return false }
        return s != .copy && actions.contains(s)
    }

    public func askAgain() {
        guard canAskAgain, let o = outcome, let s = source else { return }
        retries += 1
        if s == .onDevice {
            // the on-device model answers in JSON; it gets the errors as rules for a new answer
            run(.onDevice, PackMaker.promptB(app: world.app, menu: world.menu, docs: docs, json: true)
                + "\n\nYour last answer had these errors. Do not make them again:\n" + o.errors.map { "- \($0.message)" }.joined(separator: "\n"))
        } else {
            run(s, PackMaker.retryPrompt(o.text, errors: o.errors))
        }
    }

    func run(_ a: PackMaker.Action, _ text: String) {
        guard busy == nil else { return }
        let send = a == .openAI ? world.sendOpenAI : world.sendOnDevice
        guard let send else { status = a == .onDevice ? Self.notReady : StatusMenus.noKey(provider: world.provider) + " in the menu."; return }
        busy = a
        busySince = Date()
        source = a
        status = Self.sending(a, provider: world.provider)
        work = Task { [weak self] in
            do {
                let answer = try await send(text)
                try Task.checkCancellation()
                self?.finish(answer: answer, from: a)
            } catch {
                self?.fail(error, from: a)
            }
        }
    }

    func finish(answer: String, from a: PackMaker.Action) {
        busy = nil; busySince = nil
        if a == .onDevice {
            guard let toml = PackMaker.toml(json: answer, app: world.app) else { return show(Self.notAPack) }
            take(toml)
        } else {
            take(answer)
        }
    }

    func fail(_ e: Error, from a: PackMaker.Action) {
        busy = nil; busySince = nil
        if e is CancellationError || (e as? URLError)?.code == .cancelled { return show(Self.stopped) }
        if a == .onDevice { return show(e is ChoiceError ? Self.notReady : "The on-device model stopped: \(e.localizedDescription)") }
        show(Self.failure(e, provider: world.provider))
    }

    func show(_ s: String) {
        status = s
        if outcome == nil { notes = [] }
    }

    /// Clean, fix, lint, then the preview and the diff with the file that a save replaces.
    func take(_ answer: String) {
        guard let o = PackMaker.process(answer, app: world.app, menu: world.menu) else {
            outcome = nil; preview = nil; diff = nil; notes = []
            return show(Self.notAPack)
        }
        outcome = o
        var n = [Note]()
        if o.styleFixes > 0 { n.append(.init(.fix, Self.styleFixes(o.styleFixes))) }
        if o.menuCopies > 0 { n.append(.init(.fix, Self.menuCopies(o.menuCopies))) }
        n += o.findings.map { .init($0.level == .error ? .error : .warning, $0.message) }
        notes = n
        preview = try? PackLibrary.decode(Data(o.text.utf8))
        diff = preview.map { PackMaker.diff(old: onDisk, new: $0) }
        if o.canSave { status = "" }
        else if source == .copy { status = Self.errors(o.errors.count) + " " + Self.pasteFix }
        else { status = retries > 0 ? Self.stillErrors(o.errors.count) : Self.errors(o.errors.count) }
    }

    var file: URL { world.userPack ?? world.packsDir.appendingPathComponent(world.app.packID + ".toml") }

    /// The pack in the file that a save replaces.
    var onDisk: Pack? { (try? Data(contentsOf: file)).flatMap { try? PackLibrary.decode($0) } }

    /// Writes `<id>.toml` when the pack has no errors. An existing file is replaced only when the user says yes, and
    /// its old text goes to a `.bak` file first. After the save, the app reloads the packs and the window closes.
    public func save() {
        guard canSave, let o = outcome else { return }
        write(o.text, draft: false)
    }

    /// Writes `<id>.toml.draft`, which Sanketa does not load, for a pack that still has errors.
    public func saveDraft() {
        guard busy == nil, let o = outcome else { return }
        write(o.text, draft: true)
    }

    func write(_ text: String, draft: Bool) {
        let target = draft ? URL(fileURLWithPath: file.path + ".draft") : file
        if FileManager.default.fileExists(atPath: target.path), !world.confirmReplace(target) { return }
        do {
            try PackMaker.save(text, to: target)
            let f = target
            savedFile = f
            status = draft ? "Saved \(f.lastPathComponent). Sanketa does not load a draft." : Self.saved(f.lastPathComponent, app: world.app.name)
            world.toast(status)
            if !draft { world.saved(f); requestClose() }
        } catch {
            status = Self.saveFailed(error.localizedDescription)
            world.toast(status)
        }
    }
}
