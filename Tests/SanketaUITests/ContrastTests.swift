import AppKit
import CoreImage
import SwiftUI
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// WCAG contrast of the real panel text over approximated glass: generated backgrounds, Gaussian-blurred
/// (standing in for the glass), under the level's adaptive tint, with the real views rendered on top.
@MainActor struct ContrastTests {
    /// PNGs and numbers.tsv go to a temp dir, or to `$SANKETA_CONTRAST_OUT` when it is set.
    nonisolated static let out = ProcessInfo.processInfo.environment["SANKETA_CONTRAST_OUT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-contrast")
    nonisolated static let scale = 2.0, width = 312.0

    struct RGBA: Sendable { var px: [UInt8]; let w: Int, h: Int }

    nonisolated static func pixels(_ img: CGImage) -> RGBA {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBA(px: px, w: w, h: h)
    }

    nonisolated static func image(_ p: RGBA) -> CGImage {
        var px = p.px
        let ctx = CGContext(data: &px, width: p.w, height: p.h, bitsPerComponent: 8, bytesPerRow: p.w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// Draws a background of the given pixel size with AppKit.
    nonisolated static func background(_ kind: String, w: Int, h: Int) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = NSRect(x: 0, y: 0, width: w, height: h)
        let lines = ["$ make test && swift build -c release", "drwxr-xr-x  12 user  staff   384 Oct 24 16:02 Sources",
                     "func resolve(_ s: ProcessSnapshot) -> [Layer] {", "  PID  %CPU  RSS COMMAND", "  4521  12.3 88120 node",
                     "error: cannot find 'foo' in scope", "git log --oneline | head -20", "Lorem ipsum dolor sit amet, consectetur"]
        switch kind {
        case "terminal":
            NSColor(white: 0.11, alpha: 1).setFill(); r.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.82, alpha: 1)]
            for (i, y) in stride(from: 10, to: h, by: 36).enumerated() { (lines[i % lines.count] as NSString).draw(at: NSPoint(x: 16, y: y), withAttributes: a) }
        case "document":
            NSColor.white.setFill(); r.fill()
            let a: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Times New Roman", size: 28) ?? NSFont.systemFont(ofSize: 28),
                                                    .foregroundColor: NSColor(white: 0.13, alpha: 1)]
            for (i, y) in stride(from: 20, to: h, by: 44).enumerated() { (lines[(i + 3) % lines.count] as NSString).draw(at: NSPoint(x: 30, y: y), withAttributes: a) }
        default: // busy: hard black/white checks with saturated diagonal stripes
            for x in stride(from: 0, to: w, by: 24) { for y in stride(from: 0, to: h, by: 24) {
                ((x / 24 + y / 24) % 2 == 0 ? NSColor.black : NSColor.white).setFill()
                NSRect(x: x, y: y, width: 24, height: 24).fill()
            } }
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemBlue, .systemGreen, .magenta].enumerated() {
                c.setStroke()
                let p = NSBezierPath(); p.lineWidth = 30
                p.move(to: NSPoint(x: i * 160 - 200, y: 0)); p.line(to: NSPoint(x: i * 160 + h - 200, y: h)); p.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    nonisolated static func blur(_ img: CGImage, sigma: Double) -> CGImage {
        let ci = CIImage(cgImage: img)
        let b = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ci.extent)
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(b, from: ci.extent)!
    }

    /// Blends an opaque tint (0 = black, 255 = white) at `alpha` over every pixel.
    nonisolated static func tint(_ p: inout RGBA, _ t: Double, _ alpha: Double) {
        for i in stride(from: 0, to: p.px.count, by: 4) {
            for c in 0..<3 { p.px[i + c] = UInt8((Double(p.px[i + c]) * (1 - alpha) + t * alpha).rounded()) }
            p.px[i + 3] = 255
        }
    }

    nonisolated static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func lin(_ c: Double) -> Double { let s = c / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Contrast at every glyph-core pixel between the composited text and the backdrop behind it.
    /// Label colours are translucent (primary is 85% black in light mode), so a core is a pixel with alpha ≥ 0.25
    /// that is at least as opaque as its four neighbours: the stroke's full-colour centre, not its anti-aliased edge.
    nonisolated static func measure(text: RGBA, over bg: RGBA) -> (p10: Double, median: Double, min: Double, out: RGBA) {
        var out = bg, cs = [Double]()
        for i in stride(from: 0, to: text.px.count, by: 4) {
            let a = Double(text.px[i + 3]) / 255
            let f = (0..<3).map { Double(text.px[i + $0]) + (1 - a) * Double(bg.px[i + $0]) }
            for c in 0..<3 { out.px[i + c] = UInt8(min(255, f[c].rounded())) }
            let p = i / 4, x = p % text.w, y = p / text.w
            guard a >= 0.25, x > 0, y > 0, x < text.w - 1, y < text.h - 1 else { continue }
            let n = [p - 1, p + 1, p - text.w, p + text.w].map { Int(text.px[$0 * 4 + 3]) }.max()!
            guard Int(text.px[i + 3]) >= n - 8 else { continue }
            let lf = luminance(f[0], f[1], f[2]), lb = luminance(Double(bg.px[i]), Double(bg.px[i + 1]), Double(bg.px[i + 2]))
            cs.append((max(lf, lb) + 0.05) / (min(lf, lb) + 0.05))
        }
        cs.sort()
        precondition(!cs.isEmpty, "no glyph pixels")
        return (cs[cs.count / 10], cs[cs.count / 2], cs[0], out)
    }

    func render<V: View>(_ v: V, dark: Bool) -> CGImage {
        let r = ImageRenderer(content: v.frame(width: Self.width).environment(\.colorScheme, dark ? .dark : .light))
        r.scale = Self.scale
        r.isOpaque = false
        return r.cgImage!
    }

    /// Only the views render on the main actor; the pixel work runs off it, so other tests go on.
    @Test func textContrastOverGlass() async throws {
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(try context(["htop", "tmux", "fish", "Terminal"]))
        let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
        s.setSource(library: PackLibrary(packs: try packs()))
        s.query = "e"   // many results: keys and tips with their snippets
        let sections = VStack(alignment: .leading, spacing: 14) {
            ForEach(m.sections) { LayerSection(data: $0, collapsed: false) {} }
        }
        let results = ResultsList(results: s.results, selection: -1, prefix: s.prefix(for:), pick: { _ in }).padding(6)
        let texts = [("sections", false, AnyView(sections)), ("sections", true, AnyView(sections)),
                     ("results", false, AnyView(results)), ("results", true, AnyView(results))]
            .map { (name: $0.0, dark: $0.1, text: Self.pixels(render($0.2, dark: $0.1))) }
        // a GCD thread, not the Swift pool: this is seconds of pixel work, and other tests wait for pool threads
        let (table, failures) = try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async { c.resume(with: Result { try Self.measureAll(texts) }) }
        }
        print("contrast output: \(Self.out.path)\n" + table.joined(separator: "\n"))
        #expect(failures.isEmpty, "\(failures)")
    }

    /// Each rendered text over each blurred and tinted background; writes the PNGs and numbers.tsv.
    nonisolated static func measureAll(_ texts: [(name: String, dark: Bool, text: RGBA)]) throws -> (table: [String], failures: [String]) {
        var table = ["view\tbackground\tscheme\tlevel\tp10\tmedian\tmin"]
        var failures = [String]()
        for (vname, dark, text) in texts {
            for bg in ["terminal", "document", "busy"] {
                let raw = background(bg, w: text.w, h: text.h)
                for level in Translucency.allCases {
                    var back = pixels(blur(raw, sigma: Theme.blurRadius(level) * scale))
                    tint(&back, dark ? 0 : 255, Theme.tintOpacity(level))
                    let r = measure(text: text, over: back)
                    let scheme = dark ? "dark" : "light"
                    table.append("\(vname)\t\(bg)\t\(scheme)\t\(level.rawValue)\t" + [r.p10, r.median, r.min].map { String(format: "%.2f", $0) }.joined(separator: "\t"))
                    let png = NSBitmapImageRep(cgImage: image(r.out)).representation(using: .png, properties: [:])!
                    try png.write(to: out.appendingPathComponent("\(vname)-\(bg)-\(scheme)-\(level.rawValue).png"))
                    if level != .high && r.p10 < 4.5 { failures.append("\(vname) \(bg) \(scheme) \(level.rawValue): p10 \(r.p10)") }
                }
            }
        }
        try table.joined(separator: "\n").write(to: out.appendingPathComponent("numbers.tsv"), atomically: true, encoding: .utf8)
        return (table, failures)
    }
}

@MainActor struct KeyLabelTests {
    func width<V: View>(_ v: V) -> Int {
        let r = ImageRenderer(content: v.fixedSize())
        r.scale = 2
        return r.cgImage!.width
    }

    @Test func keyLabelAddsSpace() {
        for keys in ["⌥→", "⌃B"] {
            let plain = width(Text(keys).font(Theme.keys))
            let label = width(KeyLabel(text: keys))
            #expect(label > plain, "\(keys): KeyLabel \(label)px vs plain \(plain)px")
        }
        // chord steps get the wider gap
        #expect(width(KeyLabel(text: "⌃B  %")) >= width(KeyLabel(text: "⌃B")) + width(KeyLabel(text: "%")) + Int(KeyLabel.stepGap * 2) - 2)
        #expect(KeyLabel.tokens("🌐⌃⇧←") == ["🌐", "⌃", "⇧", "←"] && KeyLabel.tokens("⌃pgup") == ["⌃", "pgup"])
        #expect(KeyLabel.tokens("⇧esc") == ["⇧", "esc"] && KeyLabel.tokens("⌥tab") == ["⌥", "tab"])
    }
}
