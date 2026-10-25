import AppKit
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// Live, read-only: for each common app that runs now, the engine reads its menu keys as the app does on activation.
/// It never activates an app or moves focus, but it reads other apps' menus, so it runs only with SANKETA_LIVE_APPS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SANKETA_LIVE_APPS"] == "1" && AXReader.isTrusted,
                "live AX reads of running apps; set SANKETA_LIVE_APPS=1"))
struct CommonAppsLiveTests {
    static let apps: [(String, String)] = [
        ("Slack", "com.tinyspeck.slackmacgap"), ("Visual Studio Code", "com.microsoft.VSCode"), ("Chrome", "com.google.Chrome"),
        ("Safari", "com.apple.Safari"), ("Finder", "com.apple.finder"), ("Mail", "com.apple.mail"), ("Notes", "com.apple.Notes"),
        ("Messages", "com.apple.MobileSMS"), ("Word", "com.microsoft.Word"), ("Excel", "com.microsoft.Excel"),
        ("PowerPoint", "com.microsoft.Powerpoint"), ("Zoom", "us.zoom.xos"), ("Spotify", "com.spotify.client"),
        ("Kaku", "fun.tw93.kaku"), ("Conterm", "app.conterm.Conterm"), ("Leela", "org.vedicreader.leela"),
    ]
    static let packs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/Packs")
    static let minKeys = 5

    @Test func commonAppsShowMenuKeys() async throws {
        let lib = PackLibrary.load(bundled: Self.packs, user: nil)
        var rows: [String] = [], low: [String] = []
        for (name, bid) in Self.apps {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
                rows.append("\(name)\tnot running"); continue
            }
            let engine = ContextEngine(config: Config(), library: lib)
            let pid = app.processIdentifier
            let t0 = Date()
            // as on activation: a read, then the retries that the monitor makes for an empty or slow read
            let n: Int = try await offPool {
                var keys = 0
                for attempt in 0...ContextMonitor.menuRetryDelays.count {
                    let c = engine.compute(pid: pid, bundleID: bid, appName: name)
                    keys = c.packs.first { $0.id == "app:\(bid)" }?.keys.count ?? 0
                    if !c.menuIncomplete { break }
                    if attempt < ContextMonitor.menuRetryDelays.count { Thread.sleep(forTimeInterval: ContextMonitor.menuRetryDelays[attempt]) }
                }
                return keys
            }
            rows.append("\(name)\t\(n) keys\t\(String(format: "%.1f s", Date().timeIntervalSince(t0)))")
            if n < Self.minKeys { low.append("\(name): \(n)") }
        }
        print("menu keys of running apps:\n" + rows.joined(separator: "\n"))
        #expect(low.isEmpty, "\(low)")
    }
}
