import Foundation
import Testing
@testable import SanketaCore

/// Pack contexts: decoding, scope tokens from real Leela window titles, context choice, browser hosting.
@Suite struct PackContextTests {
    static let toml = """
    id = "demo"
    name = "Demo"
    apps = ["org.example.demo"]
    title_scope = ' · ([a-z]+(?::[a-z0-9]+)?)(?: [-–] [^·]*)?$'
    titles = ['(^|· )demo( — | · |$)']

    [[contexts]]
    name = "notebook"
    scopes = ["notebook"]
    groups = ["Cells", "Editing"]

    [[contexts]]
    name = "editor"
    scopes = ["py", "editor"]
    groups = ["Editing", "Refactor"]

    [[contexts]]
    name = "markdown"
    scopes = ["editor:md"]

    [[keys]]
    keys = "⌘↩"
    action = "Run cell"
    group = "Cells"

    [[keys]]
    keys = "⌘D"
    action = "Next match"
    group = "Editing"

    [[keys]]
    keys = "F2"
    action = "Rename"
    group = "Refactor"

    [[keys]]
    keys = "⌘1"
    action = "Focus files"
    group = "Panes"

    [[keys]]
    keys = "⌘B"
    action = "Bold"
    group = "Panes"
    context = "markdown"

    [[tips]]
    title = "Run all"
    snippet = "⇧⌘↩"
    tags = ["notebook"]

    [[tips]]
    title = "Preview"
    snippet = "⌘K V"
    context = "markdown"
    """

    let pack = try! PackLibrary.decode(Data(toml.utf8))

    @Test func decodesContextsAndTitleFields() {
        #expect(pack.titleScope != nil)
        #expect(pack.contexts.map(\.name) == ["notebook", "editor", "markdown"])
        #expect(pack.contexts[1].scopes == ["py", "editor"])
        #expect(pack.contexts[2].groups == [])
        #expect(pack.keys.last?.context == "markdown")
        #expect(pack.tips.last?.context == "markdown")
        #expect(pack.titles.count == 1)
        #expect(pack.titleApps == Pack.browsers)
    }

    @Test func oldPacksDecodeWithDefaults() throws {
        let p = try PackLibrary.decode(Data("id = \"x\"\nname = \"X\"\n[[keys]]\nkeys = \"a\"\naction = \"A\"\n".utf8))
        #expect(p.titleScope == nil && p.contexts.isEmpty && p.titles.isEmpty && p.keys[0].context == nil)
        #expect(p.activeContext(title: "leela — x · notebook") == nil)
    }

    @Test(arguments: [
        ("leela — sanketa · notebook", "notebook"),
        ("2⚙ (!) · leela — sanketa · notebook", "notebook"),
        ("(!) · leela — orgs · agent", "agent"),
        ("leela — orgs · editor:md", "editor:md"),
        ("leela — orgs · py", "py"),
        ("leela · terminal", "terminal"),
        ("leela — orgs · vars - Google Chrome – Work", "vars"),
    ])
    func scopeTokenFromRealTitles(_ title: String, _ token: String) {
        #expect(pack.scopeToken(title: title) == token)
    }

    @Test(arguments: ["leela — sanketa", "leela", "2⚙ · leela — orgs", ""])
    func titleWithoutTokenGivesNoContext(_ title: String) {
        #expect(pack.scopeToken(title: title) == nil)
        #expect(pack.activeContext(title: title) == nil)
    }

    @Test func choosesContextByToken() {
        #expect(pack.activeContext(title: "2⚙ (!) · leela — sanketa · notebook")?.name == "notebook")
        #expect(pack.activeContext(title: "leela — orgs · py")?.name == "editor")
        #expect(pack.activeContext(title: "leela — orgs · editor:md")?.name == "markdown")   // exact token first
        #expect(pack.activeContext(title: "leela — orgs · editor:toml")?.name == "editor")   // then `editor`
        #expect(pack.activeContext(title: "leela — orgs · web") == nil)
        #expect(pack.activeContext(title: nil) == nil)
    }

    @Test func membershipByGroupAndOverride() {
        let k = Dictionary(uniqueKeysWithValues: pack.keys.map { ($0.action, $0) })
        #expect(pack.key(k["Next match"]!, isIn: "notebook") && pack.key(k["Next match"]!, isIn: "editor"))   // shared group
        #expect(!pack.key(k["Run cell"]!, isIn: "editor"))
        #expect(!pack.key(k["Focus files"]!, isIn: "notebook"))
        #expect(pack.key(k["Bold"]!, isIn: "markdown") && !pack.key(k["Bold"]!, isIn: "editor"))           // override wins
        #expect(pack.tip(pack.tips[0], isIn: "notebook") && pack.tip(pack.tips[1], isIn: "markdown"))
    }

    @Test func searchRanksActiveContextFirst() {
        let items = SearchItem.items(from: pack, context: "editor")
        #expect(items.filter(\.active).map(\.title) == ["Next match", "Rename"])
        // `r` is a word prefix of "Run cell", "Rename" and "Run all"; the active "Rename" leads, else file order
        let ranked = Search.rank("r", items, context: ["demo"]).map(\.title)
        #expect(ranked.first == "Rename")
        let plain = Search.rank("r", SearchItem.items(from: pack), context: ["demo"]).map(\.title)
        #expect(plain.first == "Run cell")
    }

    @Test func browserHostsPackByTitle() throws {
        let lib = PackLibrary(packs: ["demo": pack])
        #expect(lib.pack(hostedIn: "com.google.Chrome", title: "demo — sanketa · notebook - Google Chrome – Work")?.id == "demo")
        #expect(lib.pack(hostedIn: "com.apple.Safari", title: "2⚙ · demo — x · py")?.id == "demo")
        #expect(lib.pack(hostedIn: "com.google.Chrome", title: "demos and more - Google Chrome") == nil)
        #expect(lib.pack(hostedIn: "com.apple.TextEdit", title: "demo — x · py") == nil)
        #expect(lib.readsTitle(bundleID: "org.example.demo") && lib.readsTitle(bundleID: "com.google.Chrome"))
        #expect(!lib.readsTitle(bundleID: "com.apple.TextEdit"))

        let r = LayerResolver(library: lib, tmux: FakeTmux(), remote: nil)
        let layers = r.resolveApp(bundleID: "com.google.Chrome", name: "Google Chrome", title: "demo — sanketa · notebook - Google Chrome")
        #expect(layers.map(\.name) == ["Demo", "Google Chrome"])
        let set = LayerResolver.applyContexts(layers, packs: [pack, nil], title: "demo — sanketa · notebook - Google Chrome")
        #expect(set.map(\.context) == ["notebook", nil])
        #expect(r.resolveApp(bundleID: "com.google.Chrome", name: "Google Chrome", title: "Inbox").map(\.name) == ["Google Chrome"])
    }

    @Test func mergeKeepsContexts() throws {
        let user = try PackLibrary.decode(Data("""
        id = "demo"
        name = "Demo"
        [[contexts]]
        name = "editor"
        scopes = ["py"]
        groups = ["Refactor"]
        [[contexts]]
        name = "vault"
        scopes = ["vault"]
        """.utf8))
        let m = PackLibrary.merge(pack, user)
        #expect(m.titleScope == pack.titleScope)
        #expect(m.contexts.map(\.name) == ["notebook", "editor", "markdown", "vault"])
        #expect(m.contexts[1].groups == ["Refactor"])
    }

    @Test func leelaContextsSurviveKeymapOverlay() throws {
        var lib = PackLibrary.load(bundled: bundledPacksDir, user: nil)
        let url = try tempDir(["keys.json": #"{"keys": {"run_cell": "alt+r"}}"#]).appendingPathComponent("keys.json")
        LeelaKeymap.apply(to: &lib, keysJSON: url)
        let p = try #require(lib.packs["leela"])
        #expect(p.contexts.map(\.name) == ["notebook", "editor", "terminal", "agent", "exec", "files", "variables", "vault", "review"])
        let groups = Set(p.keys.compactMap(\.group))
        for c in p.contexts { for g in c.groups { #expect(groups.contains(g), "\(c.name): \(g)") } }
        #expect(p.activeContext(title: "2⚙ (!) · leela — sanketa · notebook")?.name == "notebook")
        #expect(p.activeContext(title: "leela — sanketa · vars")?.name == "variables")
        #expect(p.activeContext(title: "leela — sanketa · editor:md")?.name == "editor")
        #expect(lib.pack(hostedIn: "com.google.Chrome", title: "leela — sanketa · agent - Google Chrome")?.id == "leela")
        let run = try #require(p.keys.first { $0.command == "run_cell" })
        #expect(run.keys == "⌥R" && p.key(run, isIn: "notebook"))
    }
}
