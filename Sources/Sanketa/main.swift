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

func loadLibrary() -> PackLibrary {
    let lib = PackLibrary.load(bundled: bundledPacks(), user: configDir.appendingPathComponent("packs"))
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
    if let file { try? s.write(toFile: file, atomically: true, encoding: .utf8) } else { print(s, terminator: "") }
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

let out = arg(after: "--out")
if CommandLine.arguments.contains("--dump-context") {
    dumpContext(out: out)
} else if let b = arg(after: "--dump-menus") {
    dumpMenus(b, out: out)
} else if let b = arg(after: "--dump-ax") {
    dumpAX(b, out: out)
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if !AXReader.isTrusted { AXReader.promptForTrust() }
        let monitor = ContextMonitor(config: loadConfig(), library: loadLibrary())
        monitor.start()
        app.run()
    }
}
