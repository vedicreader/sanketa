import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// The keymap fixture with the shape of ramabana's file (in SanketaCoreTests), copied to a temp folder.
let keymapFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SanketaCoreTests/Fixtures/keymaps/ramabana.json")

/// The bundled packs with the fixture as ramabana's keymap file.
func keymapLibrary() throws -> PackLibrary {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-keymaps-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: keymapFixture, to: d.appendingPathComponent("ramabana.json"))
    var lib = PackLibrary.load(bundled: bundledPacks, user: nil)
    AppKeymap.apply(to: &lib, folder: d)
    return lib
}

/// ramabana in front, its context from the window title.
func ramabanaContext(_ lib: PackLibrary, title: String?) -> Context {
    let p = lib.packs["ramabana"]!
    let l = LayerResolver.applyContexts([Layer(kind: .program, name: "ramabana", packID: "ramabana")], packs: [p], title: title)
    return Context(appName: "Kaku", bundleID: "fun.tw93.kaku", layers: l, packs: [p], axTrusted: true)
}

@MainActor @Suite struct KeymapPanelTests {
    func section(_ title: String?) throws -> (PanelModel, LayerSectionData) {
        let m = PanelModel(tips: TipStore(url: try tempURL("tips.json")), seed: 1)
        m.update(ramabanaContext(try keymapLibrary(), title: title))
        return (m, try #require(m.sections.first))
    }

    /// No context: every group shows, the context groups with their labels, all in context.
    @Test func noContextShowsEveryContextGroup() throws {
        let (_, s) = try section("~/code — ramabana")
        #expect(s.layer.context == nil)
        #expect(s.groups.map(\.name) == ["Any time", "Waiting for you", "Typing a message", "While a turn runs", "Asking for approval", "transcript", "Commands"])
        #expect(s.groups.allSatisfy { $0.inContext })
    }

    /// The current context's group first, then the keys for any time; the others under them, out of context and folded.
    @Test func theCurrentContextComesFirst() throws {
        let (m, s) = try section("ramabana · running")
        #expect(s.layer.context == "running")
        #expect(s.groups.map(\.name) == ["While a turn runs", "Any time", "Waiting for you", "Typing a message", "Asking for approval", "transcript", "Commands"])
        #expect(s.groups.map(\.inContext) == [true, true, false, false, false, false, false])
        #expect(s.groups.filter { !$0.inContext && $0.folds }.allSatisfy { m.isFolded(s, $0) })
        #expect(!m.isFolded(s, s.groups[0]))
        let (_, a) = try section("ramabana · approval")
        #expect(a.groups.prefix(2).map(\.name) == ["Asking for approval", "Any time"])
    }

    /// The held view lists only the current context's keys (and those for any time), each once.
    @Test func theHeldViewListsOnlyTheContext() throws {
        func held(_ title: String?, _ mods: Set<Modifier>) throws -> [String] {
            let (_, s) = try section(title)
            let v = ComboView.build(mods: mods, mode: "main", aero: nil, appName: "Kaku", apps: PanelModel.comboApps([s]), hyperLabel: "Caps")
            return v.app.map { "\($0.keys) \($0.action)" }
        }
        #expect(try held("ramabana · running", [.opt]) == ["↩ Queue for after this turn", "O Fold or open every turn's working rows", "1…9 Open one tool call in full"])
        #expect(try held("ramabana · approval", [.opt]) == ["O Fold or open every turn's working rows", "1…9 Open one tool call in full"])
        #expect(try held("ramabana · running", [.ctrl]) == ["C Stop the turn, keeping what is queued and typed", "D Quit, on an empty prompt",
                                                         "P / N Walk back and forward through sent prompts"])
        let all = try held(nil, [.ctrl])
        #expect(all.filter { $0 == "D Quit, on an empty prompt" }.count == 1)
        #expect(all.contains("C Clear the line") && all.contains("C Refuse"))
    }

    /// A pack that has no keymap file gives the held view every key, as before.
    @Test func otherPacksKeepEveryKey() throws {
        let lib = PackLibrary.load(bundled: bundledPacks, user: nil)
        let p = try #require(lib.packs["ramabana"])
        let s = LayerSectionData(layer: Layer(kind: .program, name: "ramabana", packID: "ramabana", context: "running"), index: 0, pack: p,
                                 groups: PanelModel.groups(p.keys))
        #expect(PanelModel.comboApps([s]).first?.entries == p.keys)
    }
}
