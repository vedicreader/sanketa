import Foundation
import Testing
@testable import SanketaCore

/// Keymap files (format 1) from a fixture with the shape of ramabana's file, in temp folders; never the person's own folder.
@Suite struct AppKeymapTests {
    static let fixture = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/keymaps/ramabana.json")
    let text = try! String(contentsOf: fixture, encoding: .utf8)
    let bundled = PackLibrary.load(bundled: bundledPacksDir, user: nil)

    func parse(_ s: String) throws -> AppKeymap { try AppKeymap.parse(Data(s.utf8)) }

    func load(_ files: [String: String]) throws -> PackLibrary {
        var lib = bundled
        AppKeymap.apply(to: &lib, folder: try tempDir(files))
        return lib
    }

    @Test func readsRowsInMacSymbols() throws {
        let m = try parse(text)
        #expect(m.app == "ramabana" && m.writtenBy == "ramabana 0.2.83" && m.skipped == 0)
        #expect(m.writtenAt == ISO8601DateFormatter().date(from: "2026-10-28T01:23:30Z") && m.writtenAt != nil)
        #expect(m.contexts.map(\.id) == ["idle", "typing", "running", "approval", "transcript"])
        #expect(m.contexts[2].label == "While a turn runs")
        func keys(_ a: String) -> String? { m.rows.first { $0.action == a }?.keys }
        #expect(keys("send") == "↩")
        #expect(keys("queue") == "⌥↩ / ⇧↩")
        #expect(keys("history") == "⌃P / ⌃N")
        #expect(keys("browse") == "↑ / ↓")
        #expect(keys("tr_match") == "n / ⇧N")
        #expect(keys("tr_leave") == "esc")
        #expect(keys("refuse") == "n ⏎")                                      // typed text stays as written
        #expect(keys("cmd_talk_main") == "/talk / /talk main")
        #expect(m.rows.first { $0.action == "browse" }?.contexts == ["idle", "running"])
        #expect(m.rows.first { $0.action == "send" }?.contexts == [])
    }

    @Test func aRangeFoldsToItsEnds() throws {
        let m = try parse(text)
        let r = try #require(m.rows.first { $0.action == "open_call" })
        #expect(r.keys == "⌥1…9")
        #expect(AppKeymap.render((1...9).map(String.init), range: true) == "1…9")
        #expect(AppKeymap.render(["hyper+1", "hyper+9"], range: true) == "Caps\u{a0}1…9")
        // the combo view shows the range without its modifier, as for a pack's "⌥1…⌥9"
        let e = KeyEntry(keys: r.keys, action: r.label)
        let v = ComboView.build(mods: [.opt], mode: "main", aero: nil, appName: "Kaku", apps: [AppKeys(layer: "ramabana", entries: [e])], hyperLabel: "Caps")
        #expect(v.app.map(\.keys) == ["1…9"])
    }

    @Test func unknownAndMissingVersionsAreRefused() {
        let v2 = text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        #expect(throws: AppKeymap.ReadError.version("2")) { try parse(v2) }
        #expect(throws: AppKeymap.ReadError.version("\"1\"")) { try parse(text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": \"1\"")) }
        #expect(throws: AppKeymap.ReadError.version("true")) { try parse(text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": true")) }
        #expect(throws: AppKeymap.ReadError.version(nil)) { try parse(#"{"app": "ramabana", "keys": []}"#) }
        #expect(AppKeymap.ReadError.version("2").message == "Sanketa does not know keymap format 2")
    }

    @Test func malformedFilesAreRefused() {
        #expect(throws: AppKeymap.ReadError.notJSON) { try parse(String(text.dropLast(40))) }
        #expect(throws: AppKeymap.ReadError.notJSON) { try parse("[1, 2]") }
        #expect(throws: AppKeymap.ReadError.notJSON) { try parse(#"{"version": 1, "app": "x", "keys": {}}"#) }
        #expect(throws: AppKeymap.ReadError.noApp) { try parse(#"{"version": 1, "keys": []}"#) }
    }

    @Test func badRowsAreSkippedAndCounted() throws {
        let m = try parse(#"{"version": 1, "app": "x", "keys": [{"action": "a", "chords": "ctrl+a", "label": "A"}, {"action": "b", "label": "B"}, 7, {"chords": ["x"], "label": ""}]}"#)
        #expect(m.rows.map(\.keys) == ["⌃A"] && m.skipped == 3)
    }

    /// Any time first, then each context with its label, a row with two contexts in both, then the typed commands.
    @Test func entriesAreGroupedByContext() throws {
        let es = try parse(text).entries
        var groups = [String]()
        for g in es.compactMap(\.group) where !groups.contains(g) { groups.append(g) }
        #expect(groups == ["Any time", "Waiting for you", "Typing a message", "While a turn runs", "Asking for approval", "Browsing the transcript", "Commands"])
        #expect(es.filter { $0.action == "Quit, on an empty prompt" }.map(\.context) == ["idle", "running"])
        #expect(es.first { $0.group == "Any time" }?.context == nil)
        #expect(es.first { $0.action == "Refuse" }?.group == "Asking for approval")
    }

    @Test func theFileWinsOverThePackKeys() throws {
        let lib = try load(["ramabana.json": text])
        let p = try #require(lib.packs["ramabana"])
        let own = try #require(bundled.packs["ramabana"])
        #expect(lib.errors.isEmpty)
        #expect(p.keymap?.hasSuffix("/ramabana.json") == true)
        #expect(p.keys.contains { $0.keys == "⌥1…9" } && !p.keys.contains { $0.keys == "⌥1…⌥9" })
        #expect(p.processes == own.processes && p.match == own.match && p.tips == own.tips)   // the pack keeps how it is found
        #expect(p.contexts.map(\.name) == ["idle", "typing", "running", "approval", "transcript"])
        #expect(p.activeContext(title: "ramabana · running")?.name == "running")
        #expect(p.activeContext(title: "notramabana · running") == nil && p.activeContext(title: "ramabana · lunch") == nil)
        // the other packs do not change
        #expect(lib.packs["leela"] == bundled.packs["leela"])
    }

    @Test func noFileKeepsThePackKeys() throws {
        let lib = try load([:])
        #expect(lib.packs["ramabana"] == bundled.packs["ramabana"] && lib.errors.isEmpty)
        var none = bundled
        AppKeymap.apply(to: &none, folder: URL(fileURLWithPath: "/nonexistent-sanketa-\(UUID().uuidString)"))
        #expect(none.packs == bundled.packs && none.errors.isEmpty)
    }

    @Test func aBadFileKeepsThePackKeysWithOneNote() throws {
        let v2 = text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 2")
        let lib = try load(["ramabana.json": v2])
        #expect(lib.packs["ramabana"] == bundled.packs["ramabana"])
        #expect(lib.errors.map(\.message) == ["Sanketa does not know keymap format 2. It uses the keys of the ramabana pack"])
        #expect(lib.errors.first?.file.hasSuffix("/ramabana.json") == true)

        let broken = try load(["ramabana.json": "{\"version\": 1, "])
        #expect(broken.packs["ramabana"] == bundled.packs["ramabana"] && broken.errors.count == 1)

        let stranger = try load(["nopack.json": text.replacingOccurrences(of: "\"app\": \"ramabana\"", with: "\"app\": \"nopack\"")])
        #expect(stranger.errors.map(\.message) == ["No pack has the id nopack. Sanketa does not use this file"])
    }

    /// A file with no usable rows must not empty the pack.
    @Test func aFileWithNoKeysKeepsThePackKeys() throws {
        for doc in [#"{"version": 1, "app": "ramabana", "keys": []}"#, #"{"version": 1, "app": "ramabana", "keys": [{"action": "a"}]}"#] {
            let lib = try load(["ramabana.json": doc])
            #expect(lib.packs["ramabana"] == bundled.packs["ramabana"])
            #expect(lib.errors.map(\.message) == ["This file has no keys Sanketa can use. It uses the keys of the ramabana pack"])
        }
    }

    /// Several files for one app: `<app>.json` wins, else the newest `written_at`; the others get a note.
    @Test func theAppsOwnFileOrTheNewestWins() throws {
        func at(_ t: String, _ chord: String) -> String {
            text.replacingOccurrences(of: "\"alt+o\"", with: "\"\(chord)\"").replacingOccurrences(of: "2026-10-28T01:23:30Z", with: t)
        }
        let lib = try load(["ramabana.json": at("2026-10-01T00:00:00Z", "alt+o"), "ramabana-old.json": at("2026-10-28T09:00:00Z", "alt+p")])
        let p = try #require(lib.packs["ramabana"])
        #expect(p.keymap?.hasSuffix("/ramabana.json") == true && p.keys.contains { $0.keys == "⌥O" })
        #expect(lib.errors.map(\.message) == ["Another file gives keys to the ramabana pack: ramabana.json. Sanketa does not use this file"])
        #expect(lib.errors.first?.file.hasSuffix("/ramabana-old.json") == true)

        let two = try load(["a.json": at("2026-10-28T09:00:00Z", "alt+p"), "b.json": at("2026-10-01T00:00:00Z", "alt+o")])
        let q = try #require(two.packs["ramabana"])
        #expect(q.keymap?.hasSuffix("/a.json") == true && q.keys.contains { $0.keys == "⌥P" })
        #expect(two.errors.map(\.message) == ["Another file gives keys to the ramabana pack: a.json. Sanketa does not use this file"])
    }

    /// Search lists a key with two contexts once, active when one of its contexts is the current one.
    @Test func searchListsEachKeyOnce() throws {
        let p = try #require(try load(["ramabana.json": text]).packs["ramabana"])
        let quit = SearchItem.items(from: p, context: "running").filter { $0.kind == .key && $0.title == "Quit, on an empty prompt" }
        #expect(quit.count == 1 && quit.first?.active == true)
        #expect(SearchItem.items(from: p, context: "approval").filter { $0.title == "Quit, on an empty prompt" }.map(\.active) == [false])
        let keys = SearchItem.items(from: p).filter { $0.kind == .key }
        #expect(Set(keys.map { $0.detail + $0.title }).count == keys.count)
    }

    @Test func theTitleRuleTakesCapitalsAndHyphens() throws {
        let p = try #require(try load(["ramabana.json": text.replacingOccurrences(of: "\"id\": \"idle\"", with: "\"id\": \"Idle-Now\"")]).packs["ramabana"])
        #expect(p.activeContext(title: "ramabana · Idle-Now")?.name == "Idle-Now")
    }

    @Test func theNoteTellsWhichKeysAreNew() throws {
        let a = try load(["ramabana.json": text])
        let b = try load(["ramabana.json": text.replacingOccurrences(of: "\"alt+o\"", with: "\"alt+p\"")])
        #expect(AppKeymap.readNote(old: a, new: b) == "Sanketa read the new keys of ramabana.")
        #expect(AppKeymap.readNote(old: b, new: b) == nil)
        #expect(AppKeymap.readNote(old: bundled, new: a) == "Sanketa read the new keys of ramabana.")
    }

    @Test func theFolderIsSetByTheEnvironment() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(AppKeymap.folder(env: [:], home: home).path == "/Users/someone/.config/sanketa/keymaps")
        #expect(AppKeymap.folder(env: ["SANKETA_KEYMAPS": "/tmp/k"], home: home).path == "/tmp/k")
    }

    /// The window title picks the program layer's context when its pack reads the title.
    @Test func aProgramLayerTakesItsContextFromTheTitle() throws {
        let p = try #require(try load(["ramabana.json": text]).packs["ramabana"])
        let layers = [Layer(kind: .program, name: "ramabana", packID: "ramabana"), Layer(kind: .program, name: "htop", packID: "htop")]
        let out = LayerResolver.applyContexts(layers, packs: [p, bundled.packs["htop"]], title: "ramabana · approval")
        #expect(out.map(\.context) == ["approval", nil])
        #expect(LayerResolver.applyContexts(layers, packs: [p, nil], title: "~/code — fish")[0].context == nil)
    }
}
