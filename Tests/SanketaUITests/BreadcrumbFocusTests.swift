import AppKit
import SwiftUI
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// The breadcrumb shows a remote host once and never cuts the tool in front; focus is a tick, not a box (P5).
@MainActor struct BreadcrumbFocusTests {
    static let remote = [Layer(kind: .program, name: "nvtop", packID: "nvtop", host: "gpubox"),
                         Layer(kind: .shell, name: "bash", packID: "bash", host: "gpubox"),
                         Layer(kind: .remote, name: "gpubox"),
                         Layer(kind: .shell, name: "fish", packID: "fish"),
                         Layer(kind: .terminal, name: "Kaku", packID: "app:fun.tw93.kaku")]

    func render<V: View>(_ v: V, width: CGFloat) -> ContrastTests.RGBA {
        let r = ImageRenderer(content: v.frame(width: width, alignment: .leading).environment(\.colorScheme, .dark))
        r.scale = 2; r.isOpaque = false
        return ContrastTests.pixels(r.cgImage!)
    }

    /// Columns `0..<w` of the image that hold any ink.
    func ink(_ p: ContrastTests.RGBA, columns: Range<Int>) -> [Bool] {
        columns.map { x in (0..<p.h).contains { y in p.px[(y * p.w + x) * 4 + 3] > 20 } }
    }

    @Test func hostShowsOnlyOnTheSSHCrumb() {
        #expect(Self.remote.map(Breadcrumb.label) == ["nvtop", "bash", "ssh gpubox", "fish", "Kaku"])
        #expect(Breadcrumb.label(Layer(kind: .app, name: "Leela", context: "notebook")) == "Leela · notebook")
    }

    /// In a narrow row the innermost crumb draws exactly as it does alone, so the cut falls on the outer crumbs.
    @Test func innermostCrumbIsNeverCut() {
        let front = Layer(kind: .program, name: "python3.13-ramabana")
        let narrow = render(Breadcrumb(layers: [front] + Self.remote, click: { _ in }), width: 200)
        let alone = render(Breadcrumb(layers: [front], click: { _ in }), width: 200)
        let w = ink(alone, columns: 0..<alone.w).lastIndex(of: true) ?? 0
        #expect(w > 100, "the crumb is \(w / 2) pt wide")
        #expect(ink(narrow, columns: 0..<(w + 1)) == ink(alone, columns: 0..<(w + 1)))
        #expect(Breadcrumb.priority(0) > Breadcrumb.priority(1) && Breadcrumb.priority(1) > Breadcrumb.priority(4))
    }

    @Test func focusIsASaffronTickNotABox() throws {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(try context(["htop", "tmux", "fish", "Terminal"]))
        let s = m.sections[1]
        func draw(_ selected: Bool) -> ContrastTests.RGBA {
            render(LayerSection(data: s, collapsed: true, selected: selected) {}, width: 312)
        }
        func saffron(_ p: ContrastTests.RGBA) -> Int {
            var n = 0
            for i in stride(from: 0, to: p.px.count, by: 4) where p.px[i + 3] > 200 {
                let r = Int(p.px[i]), g = Int(p.px[i + 1]), b = Int(p.px[i + 2])
                if abs(r - 0xE8) < 12 && abs(g - 0xA3) < 12 && abs(b - 0x3D) < 12 { n += 1 }
            }
            return n
        }
        let on = draw(true), off = draw(false)
        #expect(saffron(off) == 0)
        #expect((10...200).contains(saffron(on)), "\(saffron(on)) saffron pixels: a 2.5 × 14 pt tick at 2x is about 70")
        // no fill: a point in the empty middle of the header row stays clear
        let mid = (on.h / 2 * on.w + on.w / 2) * 4
        #expect(on.px[mid + 3] == 0)
        m.selectLayer(at: 1)
        #expect(m.focusedLayerIndex == 1)
    }

    @Test func oneSectionHidesItsName() throws {
        let finder = Context(appName: "Finder", bundleID: "com.apple.finder", layers: [Layer(kind: .app, name: "Finder", packID: terminal.id)],
                             packs: [terminal], axTrusted: true)
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(finder)
        #expect(!m.showsSectionNames)
        m.update(try context(["fish", "Terminal"]))
        #expect(m.showsSectionNames)
    }
}
