import Foundation
import Testing
@testable import SanketaCore

@Suite struct KeyWritersTests {
    let leela = """
    {
      "_help": ["x"],
      "_defaults": { "ask_ai": "hyper+a", "toggle_left": "alt+shift+b hyper+left" },
      "keys": {
        "toggle_left": "hyper+z alt+shift+b"
      }
    }
    """
    func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
    func runner() -> FakeRunner { FakeRunner(check: "", query: "") }
    func keys(_ s: String) throws -> [String: String] {
        try #require((try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])?["keys"] as? [String: String])
    }

    @Test func leelaChangesOnlyThePickedAlternativeInKeys() throws {
        let out = try LeelaKeysWriter.change(leela, action: "toggle_left", live: "hyper+z alt+shift+b", from: .leela("hyper+z")!, to: .leela("hyper+y")!)
        #expect(out.contains("\"toggle_left\": \"hyper+y alt+shift+b\""))
        #expect(out.contains("\"toggle_left\": \"alt+shift+b hyper+left\""))   // _defaults untouched
        #expect(out.replacingOccurrences(of: "hyper+y alt", with: "hyper+z alt") == leela)
    }
    @Test func leelaChangesTheSecondAlternative() throws {
        let out = try LeelaKeysWriter.change(leela, action: "toggle_left", live: "hyper+z alt+shift+b", from: .leela("alt+shift+b")!, to: .leela("alt+q")!)
        #expect(try keys(out)["toggle_left"] == "hyper+z alt+q")
        #expect(out.replacingOccurrences(of: "hyper+z alt+q", with: "hyper+z alt+shift+b") == leela)
    }
    @Test func leelaMatchesChordsNotSpellings() throws {
        let t = "{\n  \"keys\": { \"a\": \"shift+alt+b cmd+shift+k N\" }\n}\n"
        let b = try LeelaKeysWriter.change(t, action: "a", live: "", from: .leela("alt+shift+b")!, to: .leela("alt+q")!)
        #expect(try keys(b)["a"] == "alt+q cmd+shift+k N")   // the other alternatives keep the file's spelling
        let k = try LeelaKeysWriter.change(t, action: "a", live: "", from: Chord(mods: [.cmd, .shift], key: "k"), to: .leela("hyper+k")!)
        #expect(try keys(k)["a"] == "shift+alt+b hyper+k N")
        let n = try LeelaKeysWriter.change(t, action: "a", live: "", from: Chord(mods: [.shift], key: "n"), to: .leela("alt+n")!)
        #expect(try keys(n)["a"] == "shift+alt+b cmd+shift+k alt+n")
    }
    @Test func writersRefuseTheSameKey() {
        let z = Chord.leela("hyper+z")!
        #expect(throws: KeyWriteError.sameKey) { try LeelaKeysWriter.change(leela, action: "toggle_left", live: "", from: z, to: z) }
        let e = Chord.aerospace("cmd-alt-ctrl-shift-e")!
        #expect(throws: KeyWriteError.sameKey) { try AeroSpaceWriter.change(aeroSample, mode: "main", from: e, to: e) }
        #expect(KeyWriteError.sameKey.localizedDescription == "The new key is the same as the old key. Sanketa did not change the file.")
    }
    @Test func leelaAddsAMissingActionToKeys() throws {
        let out = try LeelaKeysWriter.change(leela, action: "ask_ai", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+q")!)
        let k = try keys(out)
        #expect(k["ask_ai"] == "alt+q" && k["toggle_left"] == "hyper+z alt+shift+b")
        #expect(out.contains("\"hyper+z alt+shift+b\",\n    \"ask_ai\": \"alt+q\"\n  }"))
        #expect(out.contains("\"_defaults\": { \"ask_ai\": \"hyper+a\", \"toggle_left\": \"alt+shift+b hyper+left\" },"))
    }
    @Test func leelaAddsToEmptyKeys() throws {
        let t = "{\n  \"_help\": [],\n  \"keys\": {}\n}\n"
        let out = try LeelaKeysWriter.change(t, action: "ask_ai", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+q")!)
        #expect(out == "{\n  \"_help\": [],\n  \"keys\": {\n    \"ask_ai\": \"alt+q\"\n  }\n}\n")
    }
    @Test func leelaKeepsEscapedStringsElsewhere() throws {
        let t = "{\n  \"_help\": [\"say \\\"hi\\\" {\"],\n  \"keys\": {\n    \"a\": \"hyper+a\"\n  }\n}"
        let out = try LeelaKeysWriter.change(t, action: "a", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+q")!)
        #expect(out == t.replacingOccurrences(of: "\"hyper+a\"", with: "\"alt+q\""))
    }
    @Test func leelaRefusesBadFiles() {
        #expect(throws: KeyWriteError.notJSON) { try LeelaKeysWriter.change("{", action: "a", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+a")!) }
        #expect(throws: KeyWriteError.noKeysObject) { try LeelaKeysWriter.change("{\"_defaults\": {}}", action: "a", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+a")!) }
        #expect(throws: KeyWriteError.notFound("hyper+q")) { try LeelaKeysWriter.change(leela, action: "toggle_left", live: "hyper+z", from: .leela("hyper+q")!, to: .leela("alt+a")!) }
    }
    @Test func aerospaceChangesOneLeftSide() throws {
        let out = try AeroSpaceWriter.change(aeroSample, mode: "main", from: .aerospace("cmd-alt-ctrl-shift-r")!, to: .aerospace("cmd-alt-ctrl-shift-y")!)
        #expect(out.contains("cmd-alt-ctrl-shift-y = 'mode resize'"))
        #expect(out.components(separatedBy: "\n").count == aeroSample.components(separatedBy: "\n").count)
        #expect(out.replacingOccurrences(of: "cmd-alt-ctrl-shift-y =", with: "cmd-alt-ctrl-shift-r =") == aeroSample)
        #expect(throws: KeyWriteError.notFound("cmd-alt-ctrl-shift-o")) { try AeroSpaceWriter.change(aeroSample, mode: "main", from: .aerospace("cmd-alt-ctrl-shift-o")!, to: .aerospace("cmd-alt-ctrl-shift-y")!) }
    }
    @Test func aerospaceKeepsQuotesAndHandlesLinesAfterMultiLineStrings() throws {
        let t = "[mode.main.binding]\n\"cmd-alt-ctrl-shift-x\"   =   '''a\nb'''\n  alt-ctrl-1 = 'workspace 1' # c\n"
        let q = try AeroSpaceWriter.change(t, mode: "main", from: .aerospace("cmd-alt-ctrl-shift-x")!, to: .aerospace("cmd-alt-ctrl-shift-y")!)
        #expect(q == t.replacingOccurrences(of: "shift-x", with: "shift-y"))
        let a = try AeroSpaceWriter.change(t, mode: "main", from: .aerospace("alt-ctrl-1")!, to: .aerospace("alt-ctrl-2")!)
        #expect(a == t.replacingOccurrences(of: "alt-ctrl-1 =", with: "alt-ctrl-2 ="))
    }
    @Test func aerospaceFindsOnlyTheNamedMode() {
        #expect(throws: KeyWriteError.notFound("minus")) { try AeroSpaceWriter.change(aeroSample, mode: "main", from: .aerospace("minus")!, to: .aerospace("equal")!) }
    }
    @Test func modeHookIsAddedOnce() {
        let once = AeroSpaceWriter.addModeHook(aeroSample)
        #expect(once.contains("cmd-alt-ctrl-shift-r = ['mode resize', \"exec-and-forget open -g 'sanketa://aerospace/mode/resize'\"]"))
        #expect(once.contains("esc = ['mode main', \"exec-and-forget open -g 'sanketa://aerospace/mode/main'\"]"))
        #expect(AeroSpaceWriter.addModeHook(once) == once)
        #expect(AeroSpaceConfig.parse(once).modes["main"]!.first { $0.chord.key == "r" }?.kind == .mode)
    }
    @Test func modeHookKeepsEveryOtherByte() {
        let t = "[mode.main.binding]\r\na = 'mode resize' # go\r\nb = 'workspace 1'\r\n[mode.resize.binding]\r\nesc = 'mode main'"
        let h = { (n: String) in ", \"exec-and-forget open -g 'sanketa://aerospace/mode/\(n)'\"]" }
        #expect(AeroSpaceWriter.addModeHook(t) == "[mode.main.binding]\r\na = ['mode resize'\(h("resize")) # go\r\nb = 'workspace 1'\r\n[mode.resize.binding]\r\nesc = ['mode main'\(h("main"))")
    }
    @Test func modeHookHandlesListsMultiLineValuesAndQuotedKeys() {
        let t = "[mode.main.binding]\n\"alt-a\" = ['balance-sizes', 'mode apps',]\nalt-b = [\n  'mode service',  # c\n]\nalt-c = '''mode\nresize'''\nalt-d = 'mode a b'\n"
        let out = AeroSpaceWriter.addModeHook(t)
        #expect(out.contains("\"alt-a\" = ['balance-sizes', 'mode apps', \"exec-and-forget open -g 'sanketa://aerospace/mode/apps'\",]"))
        #expect(out.contains("  'mode service', \"exec-and-forget open -g 'sanketa://aerospace/mode/service'\",  # c\n]"))
        #expect(out.contains("alt-c = ['''mode\nresize''', \"exec-and-forget open -g 'sanketa://aerospace/mode/resize'\"]\n"))
        #expect(out.hasSuffix("alt-d = 'mode a b'\n"))
        #expect(AeroSpaceWriter.addModeHook(out) == out)
        let b = AeroSpaceConfig.parse(out).modes["main"]!
        #expect(b.map(\.kind) == [.resize, .mode, .mode, .mode] && b.map(\.line) == [2, 3, 6, 8])
    }
    @Test func modeHookReplacesAHookForAnotherName() {
        let h = { (n: String) in "\"exec-and-forget open -g 'sanketa://aerospace/mode/\(n)'\"" }
        let t = "[mode.main.binding]\na = ['mode resize', \(h("old"))]\n"
        let out = AeroSpaceWriter.addModeHook(t)
        #expect(out == "[mode.main.binding]\na = ['mode resize', \(h("resize"))]\n")
        #expect(AeroSpaceWriter.addModeHook(out) == out)
    }
    @Test func nextModeKnowsOnlyMainAndConfigModes() {
        #expect(AeroSpaceConfig.nextMode("main", known: [String]()) == "main")
        #expect(AeroSpaceConfig.nextMode("resize", known: ["main", "resize"]) == "resize")
        #expect(AeroSpaceConfig.nextMode("zzz", known: ["main", "resize"]) == nil)
    }
    @Test func modeHookNeedsASafeName() {
        let t = "[mode.main.binding]\na = 'mode we!rd'\n"
        #expect(AeroSpaceWriter.addModeHook(t) == t)
    }
    @Test func describeSkipsTheModeHook() {
        let d = AeroSpaceConfig.describe(["exec-and-forget open -g 'sanketa://aerospace/mode/x'", "mode resize"])
        #expect(d.kind == .mode && d.target == "resize")
        #expect(AeroSpaceConfig.describe(["balance-sizes", "exec-and-forget open -g 'sanketa://aerospace/mode/x'"]).kind == .resize)
    }
    @Test func modeURLNeedsTheExactForm() {
        func name(_ s: String) -> String? { URL(string: s).flatMap(AeroSpaceConfig.modeName) }
        #expect(name("sanketa://aerospace/mode/resize") == "resize")
        #expect(name("sanketa://aerospace/mode/my-mode_2") == "my-mode_2")
        for bad in ["sanketa://other/mode/resize", "sanketa://aerospace/modes/resize", "sanketa://aerospace/mode/", "sanketa://aerospace/mode/a%20b",
                    "sanketa://aerospace/mode/a/b", "sanketa://aerospace/mode/a?x=1", "http://aerospace/mode/resize", "sanketa://aerospace/mode/a;b", "sanketa://aerospace"] {
            #expect(name(bad) == nil, "\(bad)")
        }
    }
    @Test func reloadCommandUsesTheFirstFoundBinary() {
        #expect(AeroSpaceWriter.reloadCommand(exists: { $0 == "/usr/local/bin/aerospace" }) == ["/usr/local/bin/aerospace", "reload-config"])
        #expect(AeroSpaceWriter.reloadCommand(exists: { _ in false }) == nil)
    }
    @Test func messagesAreExact() {
        #expect(KeyWriteError.notJSON.localizedDescription == "keys.json is not valid JSON. Sanketa did not change it.")
        #expect(KeyWriteError.noKeysObject.localizedDescription == "keys.json has no \"keys\" part. Sanketa did not change it.")
        #expect(KeyWriteError.notFound("x").localizedDescription == "Sanketa did not find x in the file.")
        #expect(KeyWriteError.changedSince("f").localizedDescription == "The file changed after the change. Undo did not run, so your edit stays.")
    }
    @Test func undoRefusesWhenTheFileChanged() throws {
        let dir = try tempDir(["k.json": "old"]), f = dir.appendingPathComponent("k.json")
        let store = KeyChangeStore(runner: runner())
        let c = KeyChange(file: f, before: "old", after: "new", reload: nil)
        _ = try store.apply(c)
        #expect(read(f) == "new" && read(dir.appendingPathComponent("k.json.sanketa-bak")) == "old")
        try "hand edit".write(to: f, atomically: true, encoding: .utf8)
        #expect(throws: KeyWriteError.changedSince(f.path)) { try store.undo(c) }
        #expect(read(f) == "hand edit")
    }
    @Test func applyReloadsAndUndoRestoresBytes() throws {
        let before = "a\r\n  b\n\u{e9}"
        let dir = try tempDir(["k.toml": before]), f = dir.appendingPathComponent("k.toml")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        let r = runner(), store = KeyChangeStore(runner: r)
        let c = KeyChange(file: f, before: before, after: "new", reload: ["/x/aerospace", "reload-config"])
        #expect(try store.apply(c))
        #expect(r.calls.map(\.path) == ["/x/aerospace"] && r.calls.map(\.args) == [["reload-config"]])
        #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int == 0o600)
        #expect(try store.undo(c))
        #expect(try Data(contentsOf: f) == Data(before.utf8))
        #expect(r.calls.count == 2)
    }
    @Test func failedReloadKeepsTheChange() throws {
        final class Fail: CommandRunning { func run(_ p: String, _ a: [String], timeout: TimeInterval) -> String? { nil } }
        let dir = try tempDir(["k": "old"]), f = dir.appendingPathComponent("k")
        let ok = try KeyChangeStore(runner: Fail()).apply(KeyChange(file: f, before: "old", after: "new", reload: ["/x", "y"]))
        #expect(!ok && (read(f)) == "new")
    }

    @Test func aerospaceHandlesCRLFAndMixedEndings() throws {
        let crlf = "[mode.main.binding]\r\nalt-a = 'x'\r\nalt-b = 'y' # c\r\n"
        let o1 = try AeroSpaceWriter.change(crlf, mode: "main", from: .aerospace("alt-b")!, to: .aerospace("alt-c")!)
        #expect(o1 == "[mode.main.binding]\r\nalt-a = 'x'\r\nalt-c = 'y' # c\r\n")
        let mixed = "# a\rb\u{2028}c\n[mode.main.binding]\nalt-a = 'x'\r\nalt-b = 'y'\n"
        let o2 = try AeroSpaceWriter.change(mixed, mode: "main", from: .aerospace("alt-b")!, to: .aerospace("alt-c")!)
        #expect(o2 == mixed.replacingOccurrences(of: "alt-b =", with: "alt-c ="))
    }
    @Test func aerospaceRefusesAKeyThatIsInUse() {
        #expect(throws: KeyWriteError.inUse("cmd-alt-ctrl-shift-r")) { try AeroSpaceWriter.change(aeroSample, mode: "main", from: .aerospace("cmd-alt-ctrl-shift-e")!, to: .aerospace("cmd-alt-ctrl-shift-r")!) }
        #expect(KeyWriteError.inUse("alt-a").localizedDescription == "alt-a is in use in AeroSpace. Sanketa did not change the file.")
    }
    @Test func leelaRefusesAValueThatIsNotAString() throws {
        let t = "{\"keys\": {\"a\": null}}"
        #expect(throws: KeyWriteError.notFound("a")) { try LeelaKeysWriter.change(t, action: "a", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+q")!) }
        let out = try LeelaKeysWriter.change(t, action: "b", live: "hyper+a", from: .leela("hyper+a")!, to: .leela("alt+q")!)
        let k = try #require((try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["keys"] as? [String: Any])
        #expect(k["a"] is NSNull && k["b"] as? String == "alt+q")
        #expect(out.hasPrefix("{\"keys\": {\"a\": null,"))
    }
    @Test func applyRefusesWhenTheFileIsNotAsBefore() throws {
        let dir = try tempDir(["k": "hand"]), f = dir.appendingPathComponent("k")
        #expect(throws: KeyWriteError.changedSince(f.path)) { try KeyChangeStore(runner: runner()).apply(KeyChange(file: f, before: "old", after: "new", reload: nil)) }
        #expect(read(f) == "hand")
    }
    @Test func symlinkedFileKeepsItsPermissionsAndStaysALink() throws {
        let dir = try tempDir(["real": "old"]), real = dir.appendingPathComponent("real"), link = dir.appendingPathComponent("link")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        _ = try KeyChangeStore(runner: runner()).apply(KeyChange(file: link, before: "old", after: "new", reload: nil))
        #expect(read(real) == "new")
        #expect(try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    }
}
