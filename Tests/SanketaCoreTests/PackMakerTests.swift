import Testing
import Foundation
@testable import SanketaCore

private let rt = PackMaker.App(name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee", version: "5.13")
private func m(_ keys: String, _ path: String...) -> MenuShortcut { MenuShortcut(path: path, keys: keys) }
private let quitMenu = [m("⌘Q", "RawTherapee", "Quit RawTherapee"), m("⌘H", "RawTherapee", "Hide RawTherapee")]
private func lintErrors(_ s: String) -> [LintFinding] { PackLint.lint(Data(s.utf8)).filter { $0.level == .error } }

private let goodBody = """
[[keys]]
keys = "⌃F2"
action = "Go to File Browser"
group = "Tabs"
"""

@Suite struct PackMakerTests {
    // 1
    @Test func fillAHasTheAppAndEachMenuLine() {
        let menu = quitMenu + [m("⇧⌘N", "File", "New Window")]
        let p = PackMaker.promptA(app: rt, menu: menu, existing: nil, urls: ["https://rawpedia.rawtherapee.com/Keyboard_Shortcuts"])
        for s in ["RawTherapee", "com.rawtherapee.RawTherapee", "rawtherapee", "5.13", "https://rawpedia.rawtherapee.com/Keyboard_Shortcuts",
                  "⌘Q  RawTherapee › Quit RawTherapee", "⇧⌘N  File › New Window", "these 3 menu shortcuts"] {
            #expect(p.contains(s), "\(s)")
        }
        #expect(!p.contains("{{"))
        #expect(!p.contains("The user already has this pack"))
        let withPack = PackMaker.promptA(app: rt, menu: menu, existing: "id = \"rawtherapee\"", urls: [])
        #expect(withPack.contains("The user already has this pack") && withPack.contains("id = \"rawtherapee\""))
        #expect(!withPack.contains("{{"))
    }

    // 2
    @Test func fillBFitsTheBudget() {
        let menu = (0..<50).map { m("⌘\($0 % 10)", "Menu", String(repeating: "x", count: $0 + 1)) }
        let filler = (0..<300).map { "This line tells a story about photo number \($0) and has no key in it." }
        let keyLines = (1...12).map { "Ctrl+\($0) selects the tool number \($0)." } + ["Press F5 to refresh.", "Shift+B compares the photo."]
        let docs = (filler + keyLines + filler).joined(separator: "\n")
        let fit = PackMaker.fitDocs(docs)
        #expect(fit.cut && fit.text.count <= PackMaker.maxDocs)
        #expect(fit.text.contains("Ctrl+12 selects") && fit.text.contains("Press F5") && fit.text.contains("Shift+B"))
        #expect(!fit.text.contains("photo number"))
        let p = PackMaker.promptB(app: rt, menu: menu, docs: docs)
        #expect(!p.contains("{{"))
        let menuPart = p.components(separatedBy: "MENU (do not repeat):\n")[1].components(separatedBy: "\n\nDOCS:")[0]
        #expect(menuPart.split(separator: "\n").count == 30)
        // the shortest lines go first
        #expect(menuPart.contains("Menu › x\n") && !menuPart.contains(String(repeating: "x", count: 31)))
        let docsPart = p.components(separatedBy: "DOCS:\n")[1]
        #expect(docsPart.trimmingCharacters(in: .whitespacesAndNewlines).count <= PackMaker.maxDocs)
        #expect(PackMaker.fitDocs("short text").text == "short text" && !PackMaker.fitDocs("short text").cut)
        let j = PackMaker.promptB(app: rt, menu: menu, docs: docs, json: true)
        #expect(j.contains("Output only JSON.") && j.contains(#"{"keys": [{"keys": "⌃S""#) && j.contains("MENU (do not repeat):"))
        #expect(!j.contains("[[keys]]") && !j.contains("Output only TOML") && !j.contains("{{"))
    }

    // 3
    @Test func ctrlRuleFollowsTheMenus() {
        let mostly = (0..<8).map { m("⌘\($0)", "A", "b\($0)") } + [m("⌃1", "A", "c"), m("⌥2", "A", "d")]
        #expect(PackMaker.ctrlRule(mostly).contains("uses ⌘"))
        #expect(PackMaker.ctrlRule([m("⌃A", "A", "a"), m("⌥B", "A", "b")]).contains("Write Ctrl as ⌃"))
        #expect(PackMaker.promptB(app: rt, menu: mostly, docs: "x").contains("This app uses ⌘ on the Mac where the docs say Ctrl."))
    }

    // 4
    @Test func privacyFilterKeepsOnlyFixedItems() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let menu = [m("⌘1", "File", "Open Recent", "IMG_0042.CR2"), m("⌘2", "Window", "trip.pp3"), m("⌘3", "History", "Some page"),
                    m("⌘C", "Edit", "Copy"), m("⌘4", "File", "\(home)/Pictures/a"), m("⌘5", "Bookmarks", "My bank"),
                    m("⌘6", "File", "Send to me@example.com"), m("⌘7", "Window", "Untitled 2")]
        let kept = PackMaker.menuLines(menu)
        #expect(kept == [m("⌘C", "Edit", "Copy")])
        let p = PackMaker.promptA(app: rt, menu: menu, existing: nil, urls: [])
        #expect(p.contains("⌘C  Edit › Copy"))
        for s in [home, NSUserName(), "IMG_0042", "trip.pp3", "Some page", "My bank", "Untitled 2"] { #expect(!p.contains(s), "\(s)") }
        #expect(!PackMaker.promptB(app: rt, menu: menu, docs: "x").contains(home))
        // Minimize and Zoom have fixed titles and stay
        #expect(PackMaker.menuLines([m("⌘M", "Window", "Minimize")]).count == 1)
    }

    // 5
    @Test func windowTitleNeverGoesIntoThePrompt() {
        // the prompt reads only the app, the menus and the user's URLs: the title has no way in
        let app = PackMaker.App(name: "RawTherapee", bundleID: "com.rawtherapee.RawTherapee", version: "5.13")
        let title = "secret.raw — RawTherapee"
        let menu = quitMenu + [m("⌘1", "Window", title)]
        let p = PackMaker.promptA(app: app, menu: menu, existing: nil, urls: [])
        #expect(!p.contains("secret"))
        #expect(!PackMaker.promptB(app: app, menu: menu, docs: "Ctrl+S saves").contains("secret"))
    }

    // 6
    @Test func cleanTakesTheTomlOutOfAFence() throws {
        let raw = "Here is the pack:\n\n```toml\n# src list\nid = \"rawtherapee\"\nname = \"RawTherapee\"\n\n\(goodBody)\n```\n\nI hope this helps."
        let c = try #require(PackMaker.clean(raw))
        #expect(c.hasPrefix("id = \"rawtherapee\"") || c.hasPrefix("# src list"))
        #expect(c.hasSuffix("group = \"Tabs\""))
        #expect(!c.contains("```") && !c.contains("hope") && !c.contains("Here is"))
        #expect(PackMaker.clean("Sorry, I cannot read that page.") == nil)
    }

    // 7
    @Test func fixTopSetsTheKnownValues() throws {
        let raw = "# top\nid = \"raw\"\nname = \"Raw\"\napps = [\"com.wrong.App\",\n  \"x\"]   # src: guess\nprocesses = [\"rawtherapee\"]\ntitle_scope = 'x(y)'\n\n\(goodBody)\n\n[[contexts]]\nname = \"editor\"\n"
        let t = PackMaker.fixTop(raw, app: rt)
        let p = try PackLibrary.decode(Data(t.utf8))
        #expect(p.id == "rawtherapee" && p.name == "RawTherapee" && p.apps == ["com.rawtherapee.RawTherapee"])
        #expect(p.processes.isEmpty && p.titleScope == nil && p.contexts.isEmpty)
        #expect(p.keys.count == 1 && t.hasPrefix("# top"))
        #expect(lintErrors(t).isEmpty, "\(lintErrors(t))")
    }

    // 8
    @Test func styleFixWritesMacKeys() throws {
        let raw = "id = \"x\"\nname = \"X\"\napps = [\"a.b\"]\n\n[[keys]]\nkeys = \"Ctrl+Shift+z\"\naction = \"Redo\"\n\n[[keys]]\nkeys = \"⇧⌃V\"\naction = \"Paste\"\n\n[[keys]]\nkeys = \"⌃S\"\naction = \"Save\"\n"
        let (t, n) = PackMaker.fixStyle(raw)
        #expect(n == 2)
        let p = try PackLibrary.decode(Data(t.utf8))
        #expect(p.keys.map(\.keys) == ["⌃⇧Z", "⌃⇧V", "⌃S"])
        #expect(lintErrors(t).isEmpty)
    }

    // 9
    @Test func menuCopiesGo() throws {
        let menu = quitMenu + [m("⇧⌘N", "File", "New Window")]
        let raw = "id = \"x\"\nname = \"X\"\napps = [\"a.b\"]\n\n[[keys]]   # src: KS\nkeys = \"⌘Q\"\naction = \"Quit\"\ngroup = \"App\"\n\n# --- Queue ---\n[[keys]]\nkeys = \"⇧⌘N\"\naction = \"Open the queue\"\ngroup = \"Queue\"\n"
        let (t, n) = PackMaker.removeMenuCopies(raw, menu: menu)
        #expect(n == 1)
        let p = try PackLibrary.decode(Data(t.utf8))
        #expect(p.keys.map(\.keys) == ["⇧⌘N"])
        #expect(t.contains("# --- Queue ---"))
    }

    // 10
    @Test func lintGatesTheSave() throws {
        let dup = "id = \"x\"\nname = \"X\"\n\n\(goodBody)\n\n\(goodBody)\n"
        let bad = try #require(PackMaker.process(dup, app: rt, menu: []))
        #expect(!bad.canSave && bad.errors.count == 1)
        let long = "id = \"x\"\nname = \"X\"\n\n[[keys]]\nkeys = \"b\"\naction = \"Show the photo before and after edits\"\ngroup = \"View\"\n"
        let ok = try #require(PackMaker.process(long, app: rt, menu: []))
        #expect(ok.canSave && ok.errors.isEmpty)
        #expect(ok.warnings.contains { $0.message.contains("7 words") })
        #expect(ok.warnings.contains { $0.message == "The pack has only 1 key. You can save it, or ask again with more docs." })
        #expect(PackMaker.process("No pack here.", app: rt, menu: []) == nil)
    }

    // 11
    @Test func trialPackIsClean() throws {
        let f = bundledPacksDir.appendingPathComponent("rawtherapee.toml")
        #expect(PackLint.lint(file: f).isEmpty, "\(PackLint.lint(file: f))")
        let text = try String(contentsOf: f, encoding: .utf8)
        // a model answer that is already right goes through the steps with no change
        let r = try #require(PackMaker.process(text, app: rt, menu: quitMenu))
        #expect(r.findings.isEmpty && r.styleFixes == 0 && r.menuCopies == 0 && r.canSave, "\(r.findings)")
        #expect(r.keyCount == 57)
    }

    // 12
    @Test func schemaBlockMatchesTheLint() {
        let names = Set(PackLint.top.map(\.name) + PackLint.key.map(\.name) + PackLint.tip.map(\.name))
        let fields = PackMaker.schema.matches(of: #/`([a-z_]+)` \((?:string|array)/#).map { String($0.1) }
        #expect(fields.count >= 9)
        for f in fields { #expect(names.contains(f), "\(f)") }
        let examples = PackMaker.schema.split(separator: "\n").filter { $0.hasPrefix("- Put the modifiers") || $0.hasPrefix("- A letter")
            || $0.hasPrefix("- Return") || $0.hasPrefix("- Arrows") || $0.hasPrefix("- A sequence") || $0.hasPrefix("- Alternatives") }
            .flatMap { line in line.split(separator: ":", maxSplits: 1).last.map { $0.matches(of: #/`([^`]+)`/#).map { String($0.1) } } ?? [] }
        let wrong: Set = ["⌘⇧P", "⇧⌃Z", "⌃s", "Enter", "Esc", "⎋", "⇥"]
        let good = examples.filter { !wrong.contains($0) }
        #expect(good.count >= 10)
        for k in good { #expect(PackLint.styleFix(k) == nil, "\(k)") }
    }

    // 13
    @Test func saveWritesAndBacksUp() throws {
        let d = try tempDir()
        let f = try PackMaker.save("id = \"rawtherapee\"\n", id: "rawtherapee", in: d)
        #expect(f == d.appendingPathComponent("rawtherapee.toml"))
        #expect(try String(contentsOf: f, encoding: .utf8) == "id = \"rawtherapee\"\n")
        _ = try PackMaker.save("id = \"rawtherapee\"\nname = \"R\"\n", id: "rawtherapee", in: d)
        #expect(try String(contentsOf: d.appendingPathComponent("rawtherapee.toml.bak"), encoding: .utf8) == "id = \"rawtherapee\"\n")
        #expect(try String(contentsOf: f, encoding: .utf8).contains("name = \"R\""))
        // a third save keeps the first backup, and the draft is a file the loader does not read
        _ = try PackMaker.save("third\n", id: "rawtherapee", in: d)
        #expect(try String(contentsOf: d.appendingPathComponent("rawtherapee.toml.bak"), encoding: .utf8) == "id = \"rawtherapee\"\n")
        #expect(try String(contentsOf: d.appendingPathComponent("rawtherapee.toml.bak2"), encoding: .utf8).contains("name = \"R\""))
        let draft = try PackMaker.save("draft\n", id: "rawtherapee", in: d, draft: true)
        #expect(draft.lastPathComponent == "rawtherapee.toml.draft")
        let files = try FileManager.default.contentsOfDirectory(atPath: d.path).sorted()
        #expect(files == ["rawtherapee.toml", "rawtherapee.toml.bak", "rawtherapee.toml.bak2", "rawtherapee.toml.draft"])
        #expect(PackLibrary.load(bundled: try tempDir(), user: d).errors.map { ($0.file as NSString).lastPathComponent } == ["rawtherapee.toml"])
    }

    // 14
    @Test func requestBodyHasOnlyThePromptAndModel() throws {
        let prompt = PackMaker.promptA(app: rt, menu: quitMenu, existing: nil, urls: [])
        let a = try #require(JSONSerialization.jsonObject(with: PackMakerRequest.body(model: "gpt-5-mini", prompt: prompt, openAI: true)) as? [String: Any])
        #expect(Set(a.keys) == ["model", "input", "tools", "store"])
        #expect(a["model"] as? String == "gpt-5-mini" && a["input"] as? String == prompt && a["store"] as? Bool == false)
        #expect((a["tools"] as? [[String: String]]) == [["type": "web_search"]])
        let b = try #require(JSONSerialization.jsonObject(with: PackMakerRequest.body(model: "llama3", prompt: prompt, openAI: false)) as? [String: Any])
        #expect(Set(b.keys) == ["model", "messages"] && b["tools"] == nil)
        #expect((b["messages"] as? [[String: String]]) == [["role": "user", "content": prompt]])
        #expect(PackMakerRequest.path(openAI: true) == "responses" && PackMakerRequest.path(openAI: false) == "chat/completions")
        let reply = #"{"output":[{"type":"web_search_call"},{"type":"message","content":[{"type":"output_text","text":"id = \"x\""}]}]}"#
        #expect(try PackMakerRequest.parse(Data(reply.utf8), openAI: true) == "id = \"x\"")
        let chat = #"{"choices":[{"message":{"content":"id = \"y\""}}]}"#
        #expect(try PackMakerRequest.parse(Data(chat.utf8), openAI: false) == "id = \"y\"")
        #expect(throws: ChoiceError.badResponse) { try PackMakerRequest.parse(Data("{}".utf8), openAI: true) }
    }

    // 15
    @Test func buttonsFollowTheToggles() {
        var c = LLMConfig()
        #expect(PackMaker.actions(c, onDeviceReady: true) == [.copy])
        c.openai = true
        #expect(PackMaker.actions(c, onDeviceReady: true) == [.copy, .openAI])
        c.onDevice = true
        #expect(PackMaker.actions(c, onDeviceReady: true) == [.copy, .openAI, .onDevice])
        #expect(PackMaker.actions(c, onDeviceReady: false) == [.copy, .openAI])
        c.openai = false
        #expect(PackMaker.actions(c, onDeviceReady: true) == [.copy, .onDevice])
    }

    @Test func jsonAnswerBecomesALintCleanPack() throws {
        let json = #"{"keys":[{"keys":"Ctrl+S","action":"Save the image","group":"Editor"},{"keys":"b","action":"Say \"hi\"","group":"View"}],"tips":[{"title":"Compare","snippet":"B","explain":"Shows before and after."}]}"#
        let t = try #require(PackMaker.toml(json: json, app: rt))
        let r = try #require(PackMaker.process(t, app: rt, menu: []))
        #expect(r.errors.isEmpty && r.styleFixes == 1, "\(r.findings)")
        let p = try PackLibrary.decode(Data(r.text.utf8))
        #expect(p.keys.map(\.keys) == ["⌃S", "b"] && p.keys[1].action == "Say \"hi\"" && p.tips.first?.explain == "Shows before and after.")
        #expect(p.apps == ["com.rawtherapee.RawTherapee"])
        #expect(PackMaker.toml(json: "not json", app: rt) == nil)
        let schema = try #require(JSONSerialization.jsonObject(with: Data(PackMaker.jsonSchema.utf8)) as? [String: Any])
        #expect(Set((schema["properties"] as? [String: Any])?.keys.map { $0 } ?? []) == ["keys", "tips"])
    }

    /// A saved shortcut page becomes text with no tags, scripts or styles, one row on each line.
    @Test func htmlFileBecomesPlainText() {
        let html = "<html><head><style>td{color:red}</style><script>var k='Ctrl';</script></head><body><h1>Keys</h1><table><tr><td>Ctrl+S</td><td>Save &amp; close</td></tr><tr><td>&lt;</td><td>Shadows</td></tr></table></body></html>"
        let t = PackMaker.plainText(html: html)
        #expect(t.contains("Ctrl+S Save & close") && t.contains("< Shadows") && t.contains("Keys"))
        #expect(!t.contains("td") && !t.contains("color:red") && !t.contains("var k") && !t.contains("&amp;"))
        #expect(PackMaker.plainText(html: "Ctrl+S saves") == "Ctrl+S saves")
    }

    @Test func diffShowsNewChangedAndRemovedKeys() {
        let old = Pack(id: "x", name: "X", keys: [KeyEntry(keys: "a", action: "A"), KeyEntry(keys: "b", action: "B")])
        let new = Pack(id: "x", name: "X", keys: [KeyEntry(keys: "a", action: "A2"), KeyEntry(keys: "c", action: "C")])
        let d = PackMaker.diff(old: old, new: new)
        #expect(d.added.map(\.keys) == ["c"] && d.changed.map(\.keys) == ["a"] && d.removed.map(\.keys) == ["b"])
        #expect(PackMaker.diff(old: nil, new: new).added.count == 2)
    }
}
