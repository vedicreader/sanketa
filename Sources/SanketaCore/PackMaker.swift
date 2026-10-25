import Foundation
import TOMLDecoder

/// "Make a Pack": the prompt for a model or a local agent, and the steps that make its answer a pack that lints.
/// The prompt holds only the app name, version, bundle id, the menu shortcuts after the privacy filter and the URLs
/// that the user typed. It never holds window titles, file names, paths or history.
public enum PackMaker {
    public struct App: Equatable, Sendable {
        public var name: String
        public var bundleID: String
        public var version: String
        /// the id of the user pack for the app when there is one, else an id from the name
        public var packID: String
        public init(name: String, bundleID: String, version: String, packID: String? = nil) {
            self.name = name; self.bundleID = bundleID; self.version = version; self.packID = PackStarter.id(packID ?? name)
        }
    }

    // MARK: prompt

    /// Words in the name of a menu whose items can name documents, pages or people.
    static let privateMenus = ["recent", "history", "bookmark", "favorite", "favourite", "profile"]

    /// True for a menu title that can name a file, a person or a place: `/`, `~`, `@`, a file extension, or the user name.
    static func isPrivate(_ title: String) -> Bool {
        if title.contains(where: { "/~@".contains($0) }) { return true }
        if title.range(of: #"\.[A-Za-z][A-Za-z0-9]{1,4}\b"#, options: .regularExpression) != nil { return true }
        return [NSUserName(), NSFullUserName()].contains { $0.count > 2 && title.localizedCaseInsensitiveContains($0) }
    }

    /// The menu shortcuts that may go into a prompt. Items in menus such as "Open Recent", "History" or "Bookmarks" go,
    /// and so do items with a private title. Window-menu items with a digit key name an open window, so they go too.
    public static func menuLines(_ shortcuts: [MenuShortcut]) -> [MenuShortcut] {
        shortcuts.filter { s in
            guard !s.keys.isEmpty, !s.path.contains(where: { t in privateMenus.contains { t.lowercased().contains($0) } || isPrivate(t) })
            else { return false }
            let windowList = s.path.first == "Window" && s.keys.range(of: #"^[⌃⌥⇧⌘🌐]*[0-9]$"#, options: .regularExpression) != nil
            return !windowList
        }
    }

    /// `⇧⌘N  File › New Window`
    public static func line(_ s: MenuShortcut) -> String { "\(s.keys)  \(s.path.joined(separator: " › "))" }

    /// The URLs that the user typed, one on each line; other text is not used.
    public static func urls(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
    }

    /// The sentence for `{{ctrl_rule}}`: ⌘ when more than half of the menu shortcuts use it.
    public static func ctrlRule(_ menu: [MenuShortcut]) -> String {
        let cmd = menu.filter { $0.keys.contains("⌘") }.count
        return cmd * 2 > menu.count ? "This app uses ⌘ on the Mac where the docs say Ctrl." : "This app keeps the Control key on the Mac. Write Ctrl as ⌃."
    }

    /// Fills `{{name}}` placeholders. A line with an empty value goes. `{{#name}}…{{/name}}` stays only when `name` has a value.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = [String](), skip = false
        for line in template.components(separatedBy: "\n") {
            if let m = line.firstMatch(of: #/^\{\{([#/])([a-z_]+)\}\}$/#) {
                if m.1 == "#" { skip = (values[String(m.2)] ?? "").isEmpty } else { skip = false }
                continue
            }
            if skip { continue }
            var l = line, empty = false
            for m in line.matches(of: #/\{\{([a-z_]+)\}\}/#) {
                let v = values[String(m.1)] ?? ""
                if v.isEmpty { empty = true; break }
                l = l.replacingOccurrences(of: String(m.0), with: v)
            }
            if !empty { out.append(l) }
        }
        return out.joined(separator: "\n")
    }

    /// Variant A, for OpenAI or a local agent: the app, the menu shortcuts after the privacy filter, the pack that the
    /// user has (its TOML) and the URLs.
    public static func promptA(app: App, menu: [MenuShortcut], existing: String?, urls: [String]) -> String {
        let lines = menuLines(menu)
        return fill(templateA, ["app_name": app.name, "app_version": app.version, "bundle_id": app.bundleID, "pack_id": app.packID,
                                "menu_keys": lines.map(line).joined(separator: "\n"), "menu_count": "\(lines.count)",
                                "existing_pack": existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                                "docs_urls": urls.joined(separator: "\n"), "schema": schema])
    }

    public static let maxMenuLinesB = 30, maxDocs = 4000

    /// A key word in a docs line: a modifier name or symbol, or a function key.
    static let keyWord = #"(?i)\b(ctrl|control|alt|shift|cmd|command|option)\b|[⌃⌥⇧⌘]|\bF([1-9]|1[0-2])\b"#

    /// The docs text in `maxDocs` characters. A longer text keeps only its lines with a key word, in order.
    public static func fitDocs(_ text: String) -> (text: String, cut: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxDocs else { return (t, false) }
        var out = [String](), n = 0
        for l in t.split(whereSeparator: \.isNewline) where l.range(of: keyWord, options: .regularExpression) != nil {
            let s = l.trimmingCharacters(in: .whitespaces)
            if n + s.count + 1 > maxDocs { break }
            out.append(s); n += s.count + 1
        }
        return (out.isEmpty ? String(t.prefix(maxDocs)) : out.joined(separator: "\n"), true)
    }

    /// Variant B, for the on-device model: at most 30 menu lines (the shortest first) and the docs text in 4,000
    /// characters. With `json`, it asks for the JSON shape that `jsonSchema` gives, and Sanketa writes the TOML.
    public static func promptB(app: App, menu: [MenuShortcut], docs: String, json: Bool = false) -> String {
        let lines = menuLines(menu)
        let short = lines.map(line).sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }.prefix(maxMenuLinesB)
        var t = fill(templateB, ["app_name": app.name, "bundle_id": app.bundleID, "pack_id": app.packID, "ctrl_rule": ctrlRule(lines),
                                 "menu_keys": short.joined(separator: "\n"), "docs_text": fitDocs(docs).text])
        if json, let a = t.range(of: "Output only TOML."), let b = t.range(of: "\nRules:") {
            t.replaceSubrange(a.lowerBound..<b.lowerBound, with: jsonShape)
            t = t.replacingOccurrences(of: "- Do not write any other fields. Do not write comments.", with: "- Do not write any other fields.")
        }
        return t
    }

    static let jsonShape = """
    Output only JSON.

    Write 10 to 25 keys and 3 to 6 tips in this shape:

    {"keys": [{"keys": "⌃S", "action": "Save the image", "group": "Editor"}],
     "tips": [{"title": "Compare with the original", "snippet": "B", "explain": "Shows the photo before and after your edits."}]}

    """

    /// The JSON schema of the on-device answer: keys and tips only. Sanketa writes the top of the pack itself.
    public static let jsonSchema: String = {
        func obj(_ fields: [String], max: Int) -> [String: Any] {
            ["type": "array", "maxItems": max, "items": [
                "type": "object", "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "string"]) }),
                "required": fields, "additionalProperties": false] as [String: Any]]
        }
        let s: [String: Any] = ["type": "object", "required": ["keys", "tips"], "additionalProperties": false,
                                "properties": ["keys": obj(["keys", "action", "group"], max: 25), "tips": obj(["title", "snippet", "explain"], max: 6)]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]), as: UTF8.self)
    }()

    /// The text of a saved HTML page: no scripts, styles or tags. A table row, a paragraph and a list item each get
    /// one line. Text that is not HTML stays as it is.
    public static func plainText(html: String) -> String {
        guard html.range(of: #"<[a-zA-Z!/][^>]*>"#, options: .regularExpression) != nil else { return html }
        var s = html.replacingOccurrences(of: #"(?is)<(script|style|head)\b.*?</\1>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/tr|/p|/li|/h[1-6]|/div|/dt|/dd)\b[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        return s.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A TOML basic string.
    public static func quote(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": o += "\\\\"
            case "\"": o += "\\\""
            case "\n": o += "\\n"
            case "\t": o += "\\t"
            case "\r": o += "\\r"
            default: o += u.value < 0x20 || u.value == 0x7F ? String(format: "\\u%04X", u.value) : String(u)
            }
        }
        return o + "\""
    }

    static func top(_ app: App) -> [String] {
        ["id = \(quote(app.packID))", "name = \(quote(app.name))", "apps = [\(quote(app.bundleID))]"]
    }

    /// The pack TOML for a JSON answer of the on-device model; nil when the answer is not that JSON.
    public static func toml(json: String, app: App) -> String? {
        struct K: Decodable { var keys: String; var action: String; var group: String? }
        struct T: Decodable { var title: String; var snippet: String; var explain: String? }
        struct A: Decodable { var keys: [K]; var tips: [T]? }
        guard let a = try? JSONDecoder().decode(A.self, from: Data(json.utf8)) else { return nil }
        var out = ["# A Sanketa pack for \(app.name), written by the on-device model. Check each key before you trust it."] + top(app)
        for k in a.keys {
            out += ["", "[[keys]]", "keys = \(quote(k.keys))", "action = \(quote(k.action))"]
            if let g = k.group, !g.isEmpty { out.append("group = \(quote(g))") }
        }
        for t in a.tips ?? [] {
            out += ["", "[[tips]]", "title = \(quote(t.title))", "snippet = \(quote(t.snippet))"]
            if let e = t.explain, !e.isEmpty { out.append("explain = \(quote(e))") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The prompt that asks the model one more time to fix the lint errors.
    public static func retryPrompt(_ toml: String, errors: [LintFinding]) -> String {
        "Fix only these errors. Output the full TOML file.\n\nERRORS:\n" + errors.map { "- \($0.message)" }.joined(separator: "\n")
            + "\n\nTOML:\n" + toml
    }

    // MARK: result

    static func isNote(_ l: String) -> Bool { let t = l.trimmingCharacters(in: .whitespaces); return t.isEmpty || t.hasPrefix("#") }

    /// The TOML of a model answer: the text in a Markdown code fence, from the first `id =` or `[[keys]]` line (with the
    /// comments just before it) to the last TOML line. Nil when the answer has no such line.
    public static func clean(_ raw: String) -> String? {
        var t = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        let fences = t.components(separatedBy: "```")
        if fences.count >= 3 {
            let inner = stride(from: 1, to: fences.count - 1, by: 2).map { fences[$0] }
            if let f = inner.first(where: { $0.contains("keys") || $0.contains("id") }) { t = String(f.drop { $0 != "\n" }) }
        }
        var lines = t.components(separatedBy: "\n")
        guard var start = lines.firstIndex(where: { $0.firstMatch(of: #/^\s*(["']?id["']?\s*=|\[\[)/#) != nil }) else { return nil }
        while start > 0, isNote(lines[start - 1]) { start -= 1 }
        lines = Array(lines[start...])
        let toml = #/^\s*([A-Za-z0-9_"'-]+\s*=|\[|\]|"|')/#
        guard let end = lines.lastIndex(where: { $0.firstMatch(of: toml) != nil }) else { return nil }
        return lines[...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A pack as the allow-list keeps it: the comments at the top, and only the fields that a GUI-app pack needs.
    struct Draft {
        struct Key { var keys, action, group: String? }
        struct Tip { var title, snippet, explain: String?; var tags: [String]? }
        var comments: [String] = []
        var keys: [Key] = []
        var tips: [Tip] = []
    }

    /// The answer decoded as TOML, with only `keys` (keys, action, group) and `tips` (title, snippet, explain, tags).
    /// Every other field goes, however it is written. Nil when the text is not valid TOML.
    static func draft(_ toml: String) -> Draft? {
        guard let root = try? TOMLDecoder().decode(TOMLValue.self, from: Data(toml.utf8)).table else { return nil }
        func tables(_ k: String) -> [[String: TOMLValue]] { root[k]?.array?.compactMap(\.table) ?? [] }
        var d = Draft()
        d.comments = toml.components(separatedBy: "\n").prefix { isNote($0) }.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("#") }
        d.keys = tables("keys").map { Draft.Key(keys: $0["keys"]?.string, action: $0["action"]?.string, group: $0["group"]?.string) }
        d.tips = tables("tips").map { t in
            Draft.Tip(title: t["title"]?.string, snippet: t["snippet"]?.string, explain: t["explain"]?.string,
                      tags: t["tags"]?.array.map { $0.compactMap(\.string) })
        }
        return d
    }

    /// The TOML of a draft, written from scratch. `id`, `name` and `apps` come from the app, not from the model.
    static func render(_ d: Draft, app: App, comments: Bool = true) -> String {
        var out = (comments && !d.comments.isEmpty ? d.comments + [""] : []) + top(app)
        func field(_ k: String, _ v: String?) { if let v { out.append("\(k) = \(quote(v))") } }
        for k in d.keys {
            out += ["", "[[keys]]"]
            field("keys", k.keys); field("action", k.action); field("group", k.group)
        }
        for t in d.tips {
            out += ["", "[[tips]]"]
            field("title", t.title); field("snippet", t.snippet); field("explain", t.explain)
            if let tags = t.tags { out.append("tags = [" + tags.map(quote).joined(separator: ", ") + "]") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The answer with only the allow-listed fields; nil when it is not valid TOML.
    public static func sanitize(_ toml: String, app: App) -> String? { draft(toml).map { render($0, app: app) } }

    /// A pack for the prompt: allow-listed fields only, with no comments.
    public static func promptPack(_ toml: String, app: App) -> String? { draft(toml).map { render($0, app: app, comments: false) } }

    /// Writes each key in the Mac key style (`PackLint.styleFix`); the count of keys it changed.
    static func fixStyle(_ d: inout Draft) -> Int {
        var n = 0
        for i in d.keys.indices {
            guard let k = d.keys[i].keys, let fix = PackLint.styleFix(k) else { continue }
            d.keys[i].keys = fix
            n += 1
        }
        return n
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(["the", "a", "an", "to", "of"])
    }

    /// Removes each key that the menus show already: the same keys and the same action words. A key with other words
    /// stays, because it gives the menu item a clearer label.
    static func removeMenuCopies(_ d: inout Draft, menu: [MenuShortcut]) -> Int {
        let before = d.keys.count
        d.keys.removeAll { k in
            guard let ks = k.keys, let a = k.action else { return false }
            let w = words(a)
            return menu.contains { s in
                guard s.keys == ks, let leaf = s.path.last else { return false }
                let lw = words(leaf)
                return !w.isEmpty && (w.isSubset(of: lw) || lw.isSubset(of: w))
            }
        }
        return before - d.keys.count
    }

    /// The result of the steps for one answer.
    public struct Outcome: Equatable {
        public var text: String
        public var styleFixes: Int
        public var menuCopies: Int
        public var keyCount: Int
        /// the lint, and a warning when the pack has fewer than `minKeys` keys
        public var findings: [LintFinding]
        public var errors: [LintFinding] { findings.filter { $0.level == .error } }
        public var warnings: [LintFinding] { findings.filter { $0.level == .warning } }
        public var canSave: Bool { errors.isEmpty }
    }

    public static let minKeys = 15
    /// An answer, a pasted text or a chosen file above these limits is not a pack.
    public static let maxText = 256 * 1024, maxKeys = 200

    public static func fewKeys(_ n: Int) -> String {
        "The pack has only \(n) key\(n == 1 ? "" : "s"). You can save it, or ask again with more docs."
    }

    /// Clean, keep only the allow-listed fields, fix the key style, remove menu copies, then lint. Nil when the answer is
    /// not a pack or is too large. An answer that is not valid TOML stays as it is, with the lint errors.
    public static func process(_ raw: String, app: App, menu: [MenuShortcut]) -> Outcome? {
        guard raw.utf8.count <= maxText, let c = clean(raw) else { return nil }
        guard var d = draft(c) else {
            return Outcome(text: c + "\n", styleFixes: 0, menuCopies: 0, keyCount: 0, findings: PackLint.lint(Data(c.utf8)))
        }
        guard d.keys.count <= maxKeys else { return nil }
        let fixes = fixStyle(&d), copies = removeMenuCopies(&d, menu: menu)
        let text = render(d, app: app)
        var findings = PackLint.lint(Data(text.utf8))
        if findings.allSatisfy({ $0.level != .error }) && d.keys.count < minKeys { findings.append(LintFinding(level: .warning, message: fewKeys(d.keys.count))) }
        return Outcome(text: text, styleFixes: fixes, menuCopies: copies, keyCount: d.keys.count, findings: findings)
    }

    // MARK: preview and save

    public struct Diff: Equatable {
        public var added: [KeyEntry], changed: [KeyEntry], removed: [KeyEntry]
    }

    /// The keys that a save adds, changes (same keys, new action) and removes, compared with the pack on disk.
    public static func diff(old: Pack?, new: Pack) -> Diff {
        let before = Dictionary((old?.keys ?? []).map { ($0.keys, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Set(new.keys.map(\.keys))
        return Diff(added: new.keys.filter { before[$0.keys] == nil },
                    changed: new.keys.filter { k in before[k.keys].map { $0.action != k.action } ?? false },
                    removed: (old?.keys ?? []).filter { !after.contains($0.keys) })
    }

    /// Writes `<id>.toml` (or `<id>.toml.draft`, which the loader does not read) in `dir`. An existing file is first
    /// copied to `<name>.bak`, or `.bak2`, `.bak3` when that exists, so no text is lost.
    @discardableResult public static func save(_ text: String, id: String, in dir: URL, draft: Bool = false) throws -> URL {
        let f = dir.appendingPathComponent(PackStarter.id(id) + (draft ? ".toml.draft" : ".toml"))
        try save(text, to: f)
        return f
    }

    /// Writes `f`; an existing file is first copied to a free `.bak` name.
    public static func save(_ text: String, to f: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: f.path) {
            var n = 1, bak: URL
            repeat { bak = URL(fileURLWithPath: f.path + ".bak" + (n == 1 ? "" : "\(n)")); n += 1 } while fm.fileExists(atPath: bak.path)
            try fm.copyItem(at: f, to: bak)
        }
        try text.write(to: f, atomically: true, encoding: .utf8)
    }

    /// The user pack whose `apps` has the bundle id, in any `.toml` file of `dir`: a save goes to that file, so the app
    /// never gets a second pack.
    public static func userPackFile(bundleID: String, in dir: URL) -> (url: URL, pack: Pack)? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "toml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            if let d = try? Data(contentsOf: f), let p = try? PackLibrary.decode(d), p.apps.contains(bundleID) { return (f, p) }
        }
        return nil
    }

    /// What Make a Pack works on.
    public enum Target: Equatable { case app(String), program(Layer), none }

    /// The GUI app in front, or the program in front in a terminal. Never Sanketa itself (`own`).
    public static func target(bundleID: String, own: String?, terminals: [String], layers: [Layer]) -> Target {
        guard !bundleID.isEmpty, bundleID != own else { return .none }
        if terminals.contains(bundleID) { return layers.first { $0.kind == .program }.map(Target.program) ?? .none }
        return .app(bundleID)
    }

    // MARK: buttons

    public enum Action: Equatable, Sendable { case copy, openAI, onDevice }

    /// Copy Prompt always; Send to OpenAI when Use OpenAI is on; Send to On-Device Model when Use On-Device Model is on
    /// and its model can run.
    public static func actions(_ c: LLMConfig, onDeviceReady: Bool) -> [Action] {
        [.copy] + (c.openai ? [.openAI] : []) + (c.onDevice && onDeviceReady ? [.onDevice] : [])
    }

    /// The line under the prompt that tells what it contains.
    public static func contents(menuCount: Int, userPack: Bool = false) -> String {
        "This prompt contains the app name, version, bundle id, \(menuCount) menu shortcut\(menuCount == 1 ? "" : "s")"
            + (userPack ? ", your URLs and the keys and tips of your pack, with no comments. " : " and your URLs. ")
            + "It does not contain window titles, file names or paths."
    }
}

/// The request for "Send to OpenAI". The body holds only the model id and the prompt that the user saw. For
/// api.openai.com it uses the Responses API with the `web_search` tool, so the model can read the docs; another server
/// gets a plain chat request with no tools.
public enum PackMakerRequest {
    public static func path(openAI: Bool) -> String { openAI ? "responses" : "chat/completions" }

    public static func body(model: String, prompt: String, openAI: Bool) -> Data {
        let b: [String: Any] = openAI
            ? ["model": model, "input": prompt, "tools": [["type": "web_search"]], "store": false]
            : ["model": model, "messages": [["role": "user", "content": prompt]]]
        return (try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])) ?? Data()
    }

    /// The answer text: the `output_text` parts of the Responses API, or `choices[0].message.content`.
    public static func parse(_ data: Data, openAI: Bool) throws -> String {
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text: String?
        if openAI {
            let parts = (j?["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }
            text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        } else {
            text = ((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, !text.isEmpty else { throw ChoiceError.badResponse }
        return text
    }
}
