import AppKit
import CoreImage
import SwiftUI
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// Draws the real panel for typical stacks over a blurred dark terminal, to PNG files for UI reviews and pull requests.
/// Off in `make test`: run `make shots` (or set `SANKETA_RENDER=1`). Files go to `$SANKETA_SHOTS_OUT` or a temp folder.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SANKETA_RENDER"] == "1"))
struct RenderTests {
    static let out = ProcessInfo.processInfo.environment["SANKETA_SHOTS_OUT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-shots")

    struct Scenario {
        var name: String
        var context: Context
        var query = ""
        var level = Translucency.medium
        var errors: [PackLoadError] = []
        var tab = false
        var setup: (@MainActor (PanelModel) -> Void)?
        var size = Theme.panelSize
    }

    static let kaku: [MenuShortcut] = [
        .init(path: ["Shell", "New Tab"], keys: "⌘T"), .init(path: ["Shell", "New Window"], keys: "⌘N"),
        .init(path: ["Shell", "Split Pane", "Right"], keys: "⌘D"), .init(path: ["Shell", "Split Pane", "Down"], keys: "⇧⌘D"),
        .init(path: ["Shell", "Close Pane"], keys: "⌘W"), .init(path: ["Edit", "Copy"], keys: "⌘C"),
        .init(path: ["Edit", "Paste"], keys: "⌘V"), .init(path: ["Edit", "Find…"], keys: "⌘F"),
        .init(path: ["Edit", "Clear Scrollback"], keys: "⌘K"), .init(path: ["View", "Bigger"], keys: "⌘+"),
        .init(path: ["View", "Smaller"], keys: "⌘-"), .init(path: ["Window", "Next Tab"], keys: "⇧⌘]"),
        .init(path: ["Window", "Previous Tab"], keys: "⇧⌘["), .init(path: ["Window", "Next Pane"], keys: "⌥⌘→", enabled: false),
    ]
    static let leelaMenu: [MenuShortcut] = [
        .init(path: ["Leela", "Settings…"], keys: "⌘,"), .init(path: ["File", "Open Folder…"], keys: "⌘O"),
        .init(path: ["Edit", "Undo"], keys: "⌘Z"), .init(path: ["Edit", "Copy"], keys: "⌘C"),
    ]
    static let finderMenu: [MenuShortcut] = [
        .init(path: ["File", "New Finder Window"], keys: "⌘N"), .init(path: ["File", "New Folder"], keys: "⇧⌘N"),
        .init(path: ["File", "Get Info"], keys: "⌘I"), .init(path: ["File", "Move to Trash"], keys: "⌘⌫"),
        .init(path: ["Edit", "Copy"], keys: "⌘C"), .init(path: ["Edit", "Paste"], keys: "⌘V", enabled: false),
        .init(path: ["View", "as Icons"], keys: "⌘1"), .init(path: ["View", "as List"], keys: "⌘2"),
        .init(path: ["View", "as Columns"], keys: "⌘3"), .init(path: ["View", "Show Path Bar"], keys: "⌥⌘P"),
        .init(path: ["Go", "Back"], keys: "⌘["), .init(path: ["Go", "Enclosing Folder"], keys: "⌘↑"),
        .init(path: ["Go", "Home"], keys: "⇧⌘H"), .init(path: ["Go", "Downloads"], keys: "⌥⌘L"),
        .init(path: ["Go", "Go to Folder…"], keys: "⇧⌘G"),
    ]

    static func ctx(_ lib: PackLibrary, _ specs: [(LayerKind, String, String?, String?)], app: String, bid: String,
                    menu: [MenuShortcut], context: String? = nil) -> Context {
        var layers = [Layer](), packs = [Pack]()
        for (k, n, pid, host) in specs {
            var l = Layer(kind: k, name: n, packID: pid, host: host)
            if k == .terminal || k == .app {
                l.packID = "app:\(bid)"; l.context = context
                var m = MenuKeys.pack(bundleID: bid, name: app, shortcuts: menu)
                if let u = lib.pack(bundleID: bid) { m = PackLibrary.merge(m, u); m.id = "app:\(bid)" }
                packs.append(m)
            } else if let pid, let p = lib.packs[pid] { packs.append(p) }
            else if pid != nil { l.packID = nil }
            layers.append(l)
        }
        return Context(appName: app, bundleID: bid, layers: layers, packs: packs, axTrusted: true)
    }

    static func scenarios(_ lib: PackLibrary) -> [Scenario] {
        let K = "fun.tw93.kaku"
        let yazi = ctx(lib, [(.program, "yazi", "yazi", nil), (.shell, "fish", "fish", nil), (.terminal, "Kaku", nil, nil)],
                       app: "Kaku", bid: K, menu: kaku)
        let htop = ctx(lib, [(.program, "htop", "htop", nil), (.multiplexer, "tmux", "tmux", nil), (.shell, "fish", "fish", nil),
                             (.terminal, "Kaku", nil, nil)], app: "Kaku", bid: K, menu: kaku)
        let leela = ctx(lib, [(.app, "Leela", nil, nil)], app: "Leela", bid: "org.vedicreader.leela", menu: leelaMenu, context: "notebook")
        let finder = ctx(lib, [(.app, "Finder", nil, nil)], app: "Finder", bid: "com.apple.finder", menu: finderMenu)
        let unknown = ctx(lib, [(.program, "duckdb", "duckdb", nil), (.shell, "fish", "fish", nil), (.terminal, "Kaku", nil, nil)],
                          app: "Kaku", bid: K, menu: kaku)
        let remote = ctx(lib, [(.program, "nvtop", "nvtop", "gpubox"), (.shell, "bash", "bash", "gpubox"), (.remote, "gpubox", nil, nil),
                               (.shell, "fish", "fish", nil), (.terminal, "Kaku", nil, nil)], app: "Kaku", bid: K, menu: kaku)
        return [
            Scenario(name: "yazi", context: yazi),
            Scenario(name: "htop-tmux", context: htop),
            Scenario(name: "leela-notebook", context: leela),
            Scenario(name: "finder", context: finder),
            Scenario(name: "search-split", context: htop, query: "split pane"),
            Scenario(name: "search-none", context: htop, query: "zzq"),
            Scenario(name: "unknown", context: unknown, errors: badPackErrors()),
            Scenario(name: "remote-gpubox", context: remote),
            Scenario(name: "tab-tmux", context: htop, tab: true),
            Scenario(name: "htop-tmux-high", context: htop, level: .high),
            Scenario(name: "tall-htop-tmux", context: htop, size: CGSize(width: 340, height: 2900)),
            Scenario(name: "htop-tmux-low", context: htop, level: .low),
        ] + comboScenarios(leela)
    }

    /// A real load error: a pack in a temp folder with a key that has no `action`.
    static func badPackErrors() -> [PackLoadError] {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-shots-bad-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? "id = \"duckdb\"\nname = \"DuckDB\"\nprocesses = [\"duckdb\"]\n\n[[keys]]\nkeys = \"⌃D\"\naction = \"Quit\"\n\n[[keys]]\nkeys = \".tables\"\n"
            .write(to: d.appendingPathComponent("duckdb.toml"), atomically: true, encoding: .utf8)
        return PackLibrary.load(bundled: d, user: nil).errors
    }

    static func terminalBackdrop(w: Int, h: Int) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        let s = CGFloat(w) / 760
        let lines: [(String, NSColor)] = [
            ("~/code/sanketa main* ❯ make test", .systemGreen), ("Building for debugging...", NSColor(white: 0.8, alpha: 1)),
            ("[42/42] Compiling SanketaUI PanelView.swift", NSColor(white: 0.8, alpha: 1)),
            ("Test run with 118 tests passed after 4.21 seconds.", .systemTeal),
            ("  PID USER   PRI  NI  VIRT   RES  S CPU% MEM%   TIME+  Command", .systemCyan),
            (" 4521 me      17   0  412G 88120 S 12.3  0.5  0:42.11 node server.js", NSColor(white: 0.85, alpha: 1)),
            ("error: cannot find 'foo' in scope", .systemRed), ("drwxr-xr-x  12 me  staff   384 Oct 24 16:02 Sources", .systemBlue),
            ("git log --oneline | head -20", .systemYellow), ("0cf99d0 Watch titles off the main thread", .systemOrange),
        ]
        for (i, y) in stride(from: CGFloat(8) * s, to: CGFloat(h), by: 21 * s).enumerated() {
            let (t, c) = lines[i % lines.count]
            (t as NSString).draw(at: NSPoint(x: 14 * s, y: y),
                                 withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13 * s, weight: .regular), .foregroundColor: c])
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    /// The panel drawn at `scale`: SwiftUI through ImageRenderer, the AppKit search field on top at its real frame.
    static func panelBitmap(_ s: Scenario, lib: PackLibrary, dark: Bool, scale: CGFloat) throws -> CGImage {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 7)
        m.update(s.context)
        m.packErrors = s.errors
        s.setup?(m)
        let search = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-shots-\(UUID().uuidString)")))
        search.setSource(library: lib, context: s.context)
        let pc = PanelController(model: m, search: search, hotkeyLabel: "⌃⌥K")
        defer { pc.panel.orderOut(nil) }
        pc.setTranslucency(s.level)
        pc.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        pc.panel.setFrame(NSRect(origin: .zero, size: s.size), display: false)
        if !s.query.isEmpty { pc.field.stringValue = s.query; search.query = s.query }
        if s.tab { pc.focusList() }
        let v = try #require(pc.panel.contentView)
        for _ in 0..<3 { v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let fr = pc.field.convert(pc.field.bounds, to: v)
        let root = PanelView(model: m, search: search, field: pc.field, grantAccessibility: {}, pick: { _ in }, clickLayer: { _ in })
            .frame(width: s.size.width, height: s.size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.imageRendering, true)
        let r = ImageRenderer(content: root)
        r.scale = scale; r.isOpaque = false
        let ui = try #require(r.cgImage)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(fr.width * scale), pixelsHigh: Int(fr.height * scale),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = fr.size
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { pc.field.cacheDisplay(in: pc.field.bounds, to: rep) }
        let c = try #require(CGContext(data: nil, width: ui.width, height: ui.height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(ui, in: CGRect(x: 0, y: 0, width: ui.width, height: ui.height))
        // the field's frame is in the flipped hosting view; the bitmap's origin is at the bottom
        let y = v.isFlipped ? CGFloat(ui.height) - fr.maxY * scale : fr.minY * scale
        c.draw(rep.cgImage!, in: CGRect(x: fr.minX * scale, y: y, width: fr.width * scale, height: fr.height * scale))
        return try #require(c.makeImage())
    }

    static func compose(_ panel: CGImage, level: Translucency, scale: CGFloat, size: CGSize) throws -> CGImage {
        let margin: CGFloat = 36
        let W = Int((size.width + margin * 2) * scale), H = Int((size.height + margin * 2) * scale)
        let back = terminalBackdrop(w: W, h: H)
        let blurred = ContrastTests.blur(back, sigma: Theme.blurRadius(level) * scale)
        let c = try #require(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let full = CGRect(x: 0, y: 0, width: W, height: H)
        c.draw(back, in: full)
        let r = CGRect(x: margin * scale, y: margin * scale, width: size.width * scale, height: size.height * scale)
        let path = CGPath(roundedRect: r, cornerWidth: 18 * scale, cornerHeight: 18 * scale, transform: nil)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        c.addPath(path); c.setFillColor(NSColor.black.cgColor); c.fillPath()
        c.restoreGState()
        c.saveGState()
        c.addPath(path); c.clip()
        c.draw(blurred, in: full)
        c.draw(panel, in: r)
        c.restoreGState()
        c.addPath(path); c.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); c.setLineWidth(1 * scale); c.strokePath()
        return try #require(c.makeImage())
    }

    @Test func drawScenarios() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        var lib = PackLibrary.load(bundled: bundledPacks, user: nil)
        LeelaKeymap.apply(to: &lib, keysJSON: nil, hyperLabel: "Caps")
        var written = [URL]()
        for s in Self.scenarios(lib) {
            for (dark, scale) in [(true, 2.0), (false, 2.0), (true, 1.0)] as [(Bool, CGFloat)] {
                let img = try Self.compose(try Self.panelBitmap(s, lib: lib, dark: dark, scale: scale), level: s.level,
                                           scale: scale, size: s.size)
                let f = Self.out.appendingPathComponent("\(s.name)-\(dark ? "dark" : "light")@\(Int(scale))x.png")
                try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: f)
                written.append(f)
            }
        }
        print("render output: \(Self.out.path) (\(written.count) files)")
        #expect(written.count == Self.scenarios(lib).count * 3)
        #expect(written.allSatisfy { NSImage(contentsOf: $0)?.size.width ?? 0 > 0 })
    }
}
