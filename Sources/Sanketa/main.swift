import AppKit
import SanketaCore
import SanketaSystem
import SanketaAI
import SanketaMLX

/// `$HOME` when it is an absolute path (tests set it to a temp folder), else the account's home folder.
let homeDir = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
    ?? FileManager.default.homeDirectoryForCurrentUser
let configDir = homeDir.appendingPathComponent(".config/sanketa")
let configURL = configDir.appendingPathComponent("config.toml")
let packsDir = configDir.appendingPathComponent("packs")

/// `Bundle.main.resourceURL/Packs` in the app; `<repo>/Resources/Packs` under `swift run`.
func bundledPacks() -> URL {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("Packs"), FileManager.default.fileExists(atPath: r.path) { return r }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
}

/// Bundled and user packs, with Leela's live keymap (keys.json) applied to the `leela` pack.
func loadLibrary(config: Config = loadConfig()) -> PackLibrary {
    var lib = PackLibrary.load(bundled: bundledPacks(), user: packsDir)
    LeelaKeymap.apply(to: &lib, keysJSON: LeelaKeymap.defaultURL(), hyperLabel: config.hyperLabel)
    for e in lib.errors { FileHandle.standardError.write(Data("pack error \(e.file): \(e.message)\n".utf8)) }
    return lib
}

/// config.toml, why it did not load (nil when it loads) and a note such as the memory fallback; both also go to stderr.
func readConfig() -> (config: Config, error: String?, note: String?) {
    let r = Config.load(configURL)
    if let err = r.error { FileHandle.standardError.write(Data("config error: \(err)\n".utf8)) }
    if let note = r.note { FileHandle.standardError.write(Data("config note: \(note)\n".utf8)) }
    return r
}

func loadConfig() -> Config { readConfig().0 }

func emit(_ lines: [String], to file: String?) {
    let s = lines.joined(separator: "\n") + "\n"
    guard let file else { return print(s, terminator: "") }
    do { try s.write(toFile: file, atomically: true, encoding: .utf8) }
    catch { FileHandle.standardError.write(Data("cannot write \(file): \(error.localizedDescription)\n".utf8)); exit(1) }
}

func running(_ bundleID: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
}

func arg(after flag: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: flag).flatMap { a.index(after: $0) < a.count ? a[a.index(after: $0)] : nil }
}

/// `--dump-context [--watch] [--pack FILE] [--delay SECONDS]`: the context of the app in front, with the reason for each pack.
func dumpContext(out: String?) {
    if let d = arg(after: "--delay").flatMap(Double.init) { RunLoop.main.run(until: Date().addingTimeInterval(d)) }
    let config = loadConfig()
    var lib = loadLibrary(config: config)
    if let f = arg(after: "--pack") {
        do {
            let p = try PackLibrary.decode(Data(contentsOf: URL(fileURLWithPath: f)))
            lib.packs[p.id] = lib.packs[p.id].map { PackLibrary.merge($0, p) } ?? p
        } catch {
            FileHandle.standardError.write(Data("\((f as NSString).lastPathComponent): \(PackLint.describe(error))\n".utf8))
            exit(1)
        }
    }
    let engine = ContextEngine(config: config, library: lib)
    func compute() -> (Context, String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier else { return nil }
        let c = engine.compute(pid: app.processIdentifier, bundleID: bid, appName: app.localizedName ?? bid)
        return (c, c.axTrusted ? AXReader.focusedWindowTitle(pid: app.processIdentifier) : nil)
    }
    guard CommandLine.arguments.contains("--watch") else {
        guard let (c, title) = compute() else { return emit(["no frontmost app"], to: out) }
        return emit(DebugInfo.context(c, title: title, showTitle: true), to: out)
    }
    // one line each time the stack changes, until Ctrl-C
    var last: [Layer]?
    let clock = DateFormatter()
    clock.dateFormat = "HH:mm:ss"
    while true {
        if let (c, _) = compute(), c.layers != last {
            last = c.layers
            print("\(clock.string(from: Date())) \(DebugInfo.stack(c))" + c.layers.compactMap { l in l.reason.map { "  [\(l.name): \($0)]" } }.joined())
            fflush(stdout)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(max(0.25, config.pollInterval)))
    }
}

func dumpMenus(_ bundleID: String, out: String?) {
    guard let app = running(bundleID) else { return emit(["not running: \(bundleID)"], to: out) }
    if !AXReader.isTrusted { FileHandle.standardError.write(Data("Accessibility not granted\n".utf8)) }
    emit(AXReader.menuShortcuts(pid: app.processIdentifier).map { "\($0.keys)\t\($0.path.joined(separator: " › "))" }, to: out)
}

func dumpAX(_ bundleID: String, out: String?) {
    guard let app = running(bundleID) else { return emit(["not running: \(bundleID)"], to: out) }
    if !AXReader.isTrusted { FileHandle.standardError.write(Data("Accessibility not granted\n".utf8)) }
    emit(AXReader.dump(pid: app.processIdentifier), to: out)
}

/// `--dump-coach [--full]`: what the coach finds in the `[coach]` history files. Each line is shell, detector id and
/// count, with no command text; `--full` adds before and after, for the user only.
func dumpCoach(out: String?) {
    let full = CommandLine.arguments.contains("--full")
    if full, out != nil {
        FileHandle.standardError.write(Data("--full does not work with --out. Shell history must not go into a file.\n".utf8))
        exit(2)
    }
    if full { FileHandle.standardError.write(Data("This output contains commands from your shell history.\n".utf8)) }
    let c = loadConfig().coach
    guard c.enabled else { return emit(["coach is off in config.toml"], to: out) }
    let es = HistoryCache().entries(fish: c.fishURL, bash: c.bashURL, maxEntries: c.maxEntries)
    emit(CoachMonitor.dumpLines(Coach.analyze(es), full: full), to: out)
}

/// The on-device slot: the `[llm] mlx_model` model. Until it is downloaded, or in a build without the MLX shaders, it
/// is unavailable, and the router goes on to Apple Intelligence, OpenAI and plain search.
func makeOnDevice(_ llm: LLMConfig) -> (any OnDeviceChooser)? {
    MLXChooser(spec: ModelCatalog.spec(llm.mlxModel), installer: ModelInstaller(root: ModelCatalog.defaultRoot))
}

/// True when this build can run the on-device model; the "On-Device Model" menu enables downloads only then.
let mlxReady = MLXRuntime.isReady

/// The model tiers for the app and `--ask`. The key comes from the environment, the login shell or the Keychain;
/// `previous` keeps the key lookup and the model list when the server stays the same.
func makeLLM(_ llm: LLMConfig, previous: LLMSetup? = nil) -> LLMSetup {
    let env = ProcessInfo.processInfo.environment
    return LLMSetup(config: llm, previous: previous, makeKeys: { account, varName in
        KeyLookup(varName: varName, env: env, shell: APIKey.loginShell(env: env, passwdShell: APIKey.passwdShell()),
                  runner: ProcessRunner(), store: KeychainStore(), account: account)
    }, onDevice: makeOnDevice(llm), appleFM: AppleFMChooser())
}

/// `--ask "<query>"`: natural-language search over the packs, as the panel does it. Prints the backend, then the top 5
/// results; a `*` marks the model's picks.
func ask(_ query: String, out: String?) {
    let config = loadConfig()
    let lib = loadLibrary(config: config)
    let llm = makeLLM(config.llm)
    let items = lib.packs.values.sorted { $0.id < $1.id }.flatMap { SearchItem.items(from: $0) }
    let timeout = config.llm.timeoutSeconds
    Task.detached {
        // one search only: wait for the on-device model to load, so the answer is not plain because it was loading
        if let mlx = llm.router.searchChooser() as? MLXChooser { try? await mlx.load() }
        let r = await SmartSearch(router: llm.router, timeout: timeout).results(query, items, context: [])
        let short = query.split(whereSeparator: \.isWhitespace).count < 3
        let backend = r.note ?? (short ? "plain search (fewer than 3 words)" : llm.router.searchChooser()?.name ?? "plain search")
        emit(["backend: \(backend)"] + r.items.prefix(5).map { "\(r.picked.contains($0.id) ? "*" : "")\($0.packID): \($0.title) — \($0.detail)" },
             to: out)
        exit(0)
    }
    dispatchMain()
}

/// `--install-model [e4b|4b|2b|4b-6bit] [--force]`: downloads and checks the on-device model (the `[llm] mlx_model` one by default).
/// While this build can't run the model, it needs `--force`.
func installModel(_ which: String?) {
    let force = CommandLine.arguments.contains("--force")
    let choice = loadConfig().llm.mlxModel
    Task.detached {
        let status = await InstallCLI.run(which: which, force: force, mlxReady: mlxReady, defaultChoice: choice,
                                          installer: ModelInstaller(root: ModelCatalog.defaultRoot),
                                          out: { print($0); fflush(stdout) },
                                          err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
        exit(status)
    }
    dispatchMain()
}

for flag in ["--dump-menus", "--dump-ax", "--out", "--pack", "--delay", "--ask"] where CommandLine.arguments.contains(flag) {
    if arg(after: flag)?.hasPrefix("--") ?? true {
        FileHandle.standardError.write(Data("""
            \(flag) needs a value
            usage: Sanketa [--dump-context [--watch] [--pack FILE] [--delay S] | --dump-menus <bundleID> | --dump-ax <bundleID>
                           | --dump-coach [--full] | --ask "<query>"] [--out FILE]
                   Sanketa --lint-pack FILE|FOLDER...
                   Sanketa --install-model [e4b|4b|2b|4b-6bit] [--force]
                   Sanketa --mlx-check

            """.utf8))
        exit(2)
    }
}

/// Asks other running Sanketa instances to quit (used to restart after a rebuild; `kill` isn't available to agents).
func quitRunning() {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.sanketa.Sanketa").filter { $0 != .current }
    for a in others { a.terminate() }
    let end = Date().addingTimeInterval(5)
    while others.contains(where: { !$0.isTerminated }) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    print("quit \(others.filter(\.isTerminated).map(\.processIdentifier)), still running \(others.filter { !$0.isTerminated }.map(\.processIdentifier))")
}

/// The arguments after `flag` up to the next `--` flag.
func args(after flag: String) -> [String] {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: flag) else { return [] }
    return Array(a[(i + 1)...].prefix { !$0.hasPrefix("--") })
}

let out = arg(after: "--out")
if CommandLine.arguments.contains("--lint-pack") {
    let paths = args(after: "--lint-pack")
    if paths.isEmpty { FileHandle.standardError.write(Data("usage: Sanketa --lint-pack FILE|FOLDER...\n".utf8)); exit(2) }
    let r = PackLint.run(paths)
    print(r.lines.joined(separator: "\n"))
    exit(r.status)
} else if CommandLine.arguments.contains("--mlx-check") {
    // smoke check for the MLX build: the metallib path and one small sum on the GPU
    guard let lib = MLXRuntime.metallibURL(), let sum = MLXRuntime.gpuCheck() else { print("metallib missing"); exit(1) }
    print("metallib \(lib.path)\ngpu sum \(sum)")
} else if CommandLine.arguments.contains("--quit-running") {
    quitRunning()
} else if let q = arg(after: "--ask") {
    ask(q, out: out)
} else if CommandLine.arguments.contains("--install-model") {
    installModel(args(after: "--install-model").first)
} else if CommandLine.arguments.contains("--dump-coach") {
    dumpCoach(out: out)
} else if CommandLine.arguments.contains("--dump-context") {
    dumpContext(out: out)
} else if let b = arg(after: "--dump-menus") {
    dumpMenus(b, out: out)
} else if let b = arg(after: "--dump-ax") {
    dumpAX(b, out: out)
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
