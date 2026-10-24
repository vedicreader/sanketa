import AppKit
import SanketaCore
import SanketaSystem

let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/sanketa")

/// `Bundle.main.resourceURL/Packs` in the app; `<repo>/Resources/Packs` under `swift run`.
func bundledPacks() -> URL {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("Packs"), FileManager.default.fileExists(atPath: r.path) { return r }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
}

/// Bundled and user packs, with Leela's live keymap (keys.json) applied to the `leela` pack.
func loadLibrary(config: Config = loadConfig()) -> PackLibrary {
    var lib = PackLibrary.load(bundled: bundledPacks(), user: configDir.appendingPathComponent("packs"))
    LeelaKeymap.apply(to: &lib, keysJSON: LeelaKeymap.defaultURL(), hyperLabel: config.hyperLabel)
    for e in lib.errors { FileHandle.standardError.write(Data("pack error \(e.file): \(e.message)\n".utf8)) }
    return lib
}

func loadConfig() -> Config {
    let (c, err) = Config.load(configDir.appendingPathComponent("config.toml"))
    if let err { FileHandle.standardError.write(Data("config error: \(err)\n".utf8)) }
    return c
}

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

func dumpContext(out: String?) {
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier else {
        return emit(["no frontmost app"], to: out)
    }
    let c = ContextEngine(config: loadConfig(), library: loadLibrary())
        .compute(pid: app.processIdentifier, bundleID: bid, appName: app.localizedName ?? bid)
    emit(["app: \(c.appName) (\(c.bundleID)) axTrusted=\(c.axTrusted)", "layers:"]
         + c.layers.map { "  \($0.kind.rawValue) \($0.name) pack=\($0.packID ?? "-")\($0.host.map { " host=\($0)" } ?? "")" }
         + ["packs:"] + c.packs.map { "  \($0.id) keys=\($0.keys.count) tips=\($0.tips.count)\($0.prefix.map { " prefix=\($0)" } ?? "")" },
         to: out)
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

for flag in ["--dump-menus", "--dump-ax", "--out"] where CommandLine.arguments.contains(flag) {
    if arg(after: flag)?.hasPrefix("--") ?? true {
        FileHandle.standardError.write(Data("""
            \(flag) needs a value
            usage: Sanketa [--dump-context | --dump-menus <bundleID> | --dump-ax <bundleID>] [--out FILE]

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
