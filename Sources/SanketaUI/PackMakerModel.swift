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
        /// the TOML of the pack that the user has for the app, for the prompt
        public var existing: String?
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

        public init(app: PackMaker.App, menu: [MenuShortcut], existing: String?, config: LLMConfig, provider: String, onDeviceReady: Bool,
                    sendOpenAI: ((String) async throws -> String)?, sendOnDevice: ((String) async throws -> String)?,
                    packsDir: URL, pasteboard: NSPasteboard = .general, confirmReplace: @escaping (URL) -> Bool, saved: @escaping (URL) -> Void) {
            self.app = app; self.menu = menu; self.existing = existing; self.config = config; self.provider = provider
            self.onDeviceReady = onDeviceReady; self.sendOpenAI = sendOpenAI; self.sendOnDevice = sendOnDevice; self.packsDir = packsDir
            self.pasteboard = pasteboard; self.confirmReplace = confirmReplace; self.saved = saved
        }
    }

    let world: World
    /// the docs URLs that the user types, one on each line
    @Published public var urls = "" { didSet { prompt = Self.promptA(world, urls) } }
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
    /// the lines under the status: style fixes, removed menu copies, lint errors and warnings
    @Published public private(set) var notes: [String] = []
    @Published public private(set) var preview: Pack?
    @Published public private(set) var diff: PackMaker.Diff?
    @Published public private(set) var savedFile: URL?
    /// the request that runs, so tests can wait for it
    public private(set) var work: Task<Void, Never>?
    /// where the last answer came from, and how many times the model got the errors back
    var source: PackMaker.Action?
    var retries = 0

    public init(_ world: World) {
        self.world = world
        prompt = Self.promptA(world, "")
    }

    static func promptA(_ w: World, _ urls: String) -> String {
        PackMaker.promptA(app: w.app, menu: w.menu, existing: w.existing, urls: PackMaker.urls(urls))
    }

    public var app: PackMaker.App { world.app }
    public var actions: [PackMaker.Action] { PackMaker.actions(world.config, onDeviceReady: world.onDeviceReady) }
    public var contents: String { PackMaker.contents(menuCount: PackMaker.menuLines(world.menu).count) }
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
        a == .onDevice ? "The on-device model is writing the pack." : "\(provider) is reading the docs. This can take 2 minutes."
    }

    static func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    public static func errors(_ n: Int) -> String { "The pack has \(count(n, "error")). Sanketa can ask the model to fix them." }
    public static func stillErrors(_ n: Int) -> String { "The pack still has \(count(n, "error")). Save it as a draft, or edit it." }
    public static func styleFixes(_ n: Int) -> String { "Sanketa changed \(count(n, "key")) to the Mac key style." }
    public static func menuCopies(_ n: Int) -> String { "Sanketa removed \(count(n, "key")) that the menus already show." }
    public static func saved(_ file: String, app: String) -> String { "Saved \(file). The keys show when \(app) is in front." }
    public static func saveFailed(_ why: String) -> String { "Sanketa cannot write the file: \(why)." }

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

    /// Ends the request that runs.
    public func stop() {
        work?.cancel()
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
        busy = nil
        if a == .onDevice {
            guard let toml = PackMaker.toml(json: answer, app: world.app) else { return show(Self.notAPack) }
            take(toml)
        } else {
            take(answer)
        }
    }

    func fail(_ e: Error, from a: PackMaker.Action) {
        busy = nil
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
        var n = [String]()
        if o.styleFixes > 0 { n.append(Self.styleFixes(o.styleFixes)) }
        if o.menuCopies > 0 { n.append(Self.menuCopies(o.menuCopies)) }
        n += o.findings.map(\.description)
        notes = n
        preview = try? PackLibrary.decode(Data(o.text.utf8))
        diff = preview.map { PackMaker.diff(old: onDisk, new: $0) }
        if o.canSave { status = "" }
        else if source == .copy { status = Self.errors(o.errors.count) + " " + Self.pasteFix }
        else { status = retries > 0 ? Self.stillErrors(o.errors.count) : Self.errors(o.errors.count) }
    }

    var file: URL { world.packsDir.appendingPathComponent(world.app.packID + ".toml") }

    /// The pack in the file that a save replaces.
    var onDisk: Pack? { (try? Data(contentsOf: file)).flatMap { try? PackLibrary.decode($0) } }

    /// Writes `<id>.toml` when the pack has no errors. An existing file is replaced only when the user says yes, and
    /// its old text goes to a `.bak` file first.
    public func save() {
        guard let o = outcome, o.canSave else { return }
        write(o.text, draft: false)
    }

    /// Writes `<id>.toml.draft`, which Sanketa does not load, for a pack that still has errors.
    public func saveDraft() {
        guard let o = outcome else { return }
        write(o.text, draft: true)
    }

    func write(_ text: String, draft: Bool) {
        let target = draft ? URL(fileURLWithPath: file.path + ".draft") : file
        if FileManager.default.fileExists(atPath: target.path), !world.confirmReplace(target) { return }
        do {
            let f = try PackMaker.save(text, id: world.app.packID, in: world.packsDir, draft: draft)
            savedFile = f
            status = draft ? "Saved \(f.lastPathComponent). Sanketa does not load a draft." : Self.saved(f.lastPathComponent, app: world.app.name)
            if !draft { world.saved(f) }
        } catch {
            status = Self.saveFailed(error.localizedDescription)
        }
    }
}
