import AppKit
import SanketaCore
import SanketaSystem

let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sanketa")
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

/// config.toml and why it did not load (nil when it loads); errors also go to stderr.
func readConfig() -> (Config, String?) {
    let (c, err) = Config.load(configURL)
    if let err { FileHandle.standardError.write(Data("config error: \(err)\n".utf8)) }
    return (c, err)
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

for flag in ["--dump-menus", "--dump-ax", "--out", "--pack", "--delay"] where CommandLine.arguments.contains(flag) {
    if arg(after: flag)?.hasPrefix("--") ?? true {
        FileHandle.standardError.write(Data("""
            \(flag) needs a value
            usage: Sanketa [--dump-context [--watch] [--pack FILE] [--delay S] | --dump-menus <bundleID> | --dump-ax <bundleID>] [--out FILE]
                   Sanketa --lint-pack FILE|FOLDER...

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
} else if CommandLine.arguments.contains("--quit-running") {
    quitRunning()
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
