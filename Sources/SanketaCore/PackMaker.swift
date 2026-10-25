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
        public init(name: String, bundleID: String, version: String) { self.name = name; self.bundleID = bundleID; self.version = version }
        public var packID: String { PackStarter.id(name) }
    }

    // MARK: prompt

    /// Menus whose items name documents or pages.
    static let privateMenus: Set<String> = ["open recent", "recent", "recent items", "history", "bookmarks"]

    /// True for a menu title that can name a file, a person or a place: `/`, `~`, `@`, a file extension, or the user name.
    static func isPrivate(_ title: String) -> Bool {
        if title.contains(where: { "/~@".contains($0) }) { return true }
        if title.range(of: #"\.[A-Za-z][A-Za-z0-9]{1,4}\b"#, options: .regularExpression) != nil { return true }
        return [NSUserName(), NSFullUserName()].contains { $0.count > 2 && title.localizedCaseInsensitiveContains($0) }
    }

    /// The menu shortcuts that may go into a prompt. Items in recent-file and history menus go, and so do items with a
    /// private title. Window-menu items with ⌘ and a digit name an open window, so they go too.
    public static func menuLines(_ shortcuts: [MenuShortcut]) -> [MenuShortcut] {
        shortcuts.filter { s in
            guard !s.keys.isEmpty, !s.path.contains(where: { privateMenus.contains($0.lowercased()) || isPrivate($0) }) else { return false }
            let windowList = s.path.first == "Window" && s.keys.range(of: #"^⌘[0-9]$"#, options: .regularExpression) != nil
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

    /// One table of the TOML text, with its header line (none for the top), and the comment lines before it.
    struct Block { var name: String?; var lines: [String] }

    /// The change in `[` `]` depth of a TOML line, outside strings and comments.
    static func depth(_ line: String) -> Int {
        var d = 0, quote: Character?, escape = false
        for c in line {
            if let q = quote {
                if escape { escape = false } else if c == "\\" && q == "\"" { escape = true } else if c == q { quote = nil }
                continue
            }
            switch c {
            case "\"", "'": quote = c
            case "#": return d
            case "[": d += 1
            case "]": d -= 1
            default: break
            }
        }
        return d
    }

    static func isNote(_ l: String) -> Bool { let t = l.trimmingCharacters(in: .whitespaces); return t.isEmpty || t.hasPrefix("#") }

    /// The text as the top block and one block for each table. The comments just before a header go with that table.
    static func blocks(_ text: String) -> [Block] {
        var out = [Block(name: nil, lines: [])], d = 0
        for line in text.components(separatedBy: "\n") {
            if d == 0, let m = line.firstMatch(of: #/^\s*\[\[?\s*([A-Za-z0-9_.-]+)\s*\]\]?/#) {
                var notes = [String]()
                while let last = out[out.count - 1].lines.last, isNote(last) { notes.insert(out[out.count - 1].lines.removeLast(), at: 0) }
                out.append(Block(name: String(m.1), lines: notes + [line]))
                continue
            }
            out[out.count - 1].lines.append(line)
            d = max(0, d + depth(line))
        }
        return out
    }

    static func join(_ b: [Block]) -> String { b.flatMap(\.lines).joined(separator: "\n") }

    /// The fields of a table block, read as TOML; the header line does not count.
    static func table(_ b: Block) -> [String: TOMLValue]? {
        let header = b.name == nil ? -1 : b.lines.firstIndex { $0.firstMatch(of: #/^\s*\[/#) != nil } ?? -1
        let body = b.lines.dropFirst(header + 1)
        return try? TOMLDecoder().decode(TOMLValue.self, from: Data(body.joined(separator: "\n").utf8)).table
    }

    /// The TOML of a model answer: the text in a Markdown code fence, from the first `id =` or `[[keys]]` line (with the
    /// comments just before it) to the last TOML line. Nil when the answer has no such line.
    public static func clean(_ raw: String) -> String? {
        var t = raw.replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
        let fences = t.components(separatedBy: "```")
        if fences.count >= 3 {
            let inner = stride(from: 1, to: fences.count - 1, by: 2).map { fences[$0] }
            if let f = inner.first(where: { $0.contains("[[keys]]") || $0.contains("id =") }) { t = String(f.drop { $0 != "\n" }) }
        }
        var lines = t.components(separatedBy: "\n")
        guard var start = lines.firstIndex(where: { $0.firstMatch(of: #/^\s*(id\s*=|\[\[keys\]\])/#) != nil }) else { return nil }
        while start > 0, isNote(lines[start - 1]) { start -= 1 }
        lines = Array(lines[start...])
        let toml = #/^\s*([A-Za-z0-9_"'-]+\s*=|\[|\]|"|')/#
        guard let end = lines.lastIndex(where: { $0.firstMatch(of: toml) != nil }) else { return nil }
        return lines[...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Top-level fields that the pack must not have: Sanketa knows the app, so the pack shows only by its bundle id.
    static let dropTop: Set = ["id", "name", "apps", "processes", "match", "prefix", "title_scope", "contexts"]

    /// Sets `id`, `name` and `apps` to the app's values, and removes the other ways to show and the contexts.
    public static func fixTop(_ text: String, app: App) -> String {
        var b = blocks(text).filter { $0.name != "contexts" && $0.name?.hasPrefix("contexts.") != true }
        var head = [String](), d = 0, dropping = false
        for line in b[0].lines {
            if d == 0, let m = line.firstMatch(of: #/^\s*([A-Za-z_]+)\s*=/#) { dropping = dropTop.contains(String(m.1)) }
            else if d == 0 { dropping = false }
            d = max(0, d + depth(line))
            if !dropping { head.append(line) }
        }
        let lead = head.prefix { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        var rest = Array(head.dropFirst(lead.count))
        while let f = rest.first, f.trimmingCharacters(in: .whitespaces).isEmpty { rest.removeFirst() }
        b[0].lines = Array(lead) + (lead.isEmpty ? [] : [""]) + top(app) + rest
        if b.count > 1, !(b[0].lines.last ?? "").isEmpty, !(b[1].lines.first ?? "").isEmpty { b[0].lines.append("") }
        return join(b)
    }

    /// Writes each key in the Mac key style (`PackLint.styleFix`); the count of keys it changed.
    public static func fixStyle(_ text: String) -> (text: String, fixes: Int) {
        var b = blocks(text), n = 0
        for i in b.indices where b[i].name == "keys" && table(b[i])?["command"] == nil {
            for j in b[i].lines.indices {
                guard let m = b[i].lines[j].firstMatch(of: #/^(\s*keys\s*=\s*)(.*)$/#),
                      let v = try? TOMLDecoder().decode(TOMLValue.self, from: Data("v = \(m.2)".utf8)).table?["v"]?.string,
                      let fix = PackLint.styleFix(v) else { continue }
                b[i].lines[j] = "\(m.1)\(quote(fix))"
                n += 1
            }
        }
        return (join(b), n)
    }

    static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting(["the", "a", "an", "to", "of"])
    }

    /// Removes each key that the menus show already: the same keys and the same action words. A key with other words
    /// stays, because it gives the menu item a clearer label.
    public static func removeMenuCopies(_ text: String, menu: [MenuShortcut]) -> (text: String, removed: Int) {
        var n = 0
        let b = blocks(text).filter { blk in
            guard blk.name == "keys", let t = table(blk), let k = t["keys"]?.string, let a = t["action"]?.string else { return true }
            let w = words(a)
            let copy = menu.contains { s in
                guard s.keys == k, let leaf = s.path.last else { return false }
                let lw = words(leaf)
                return !w.isEmpty && (w.isSubset(of: lw) || lw.isSubset(of: w))
            }
            if copy { n += 1 }
            return !copy
        }
        return (join(b), n)
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

    public static func fewKeys(_ n: Int) -> String {
        "The pack has only \(n) key\(n == 1 ? "" : "s"). You can save it, or ask again with more docs."
    }

    /// Clean, fix the top, fix the key style, remove menu copies, then lint. Nil when the answer is not a pack.
    public static func process(_ raw: String, app: App, menu: [MenuShortcut]) -> Outcome? {
        guard let c = clean(raw) else { return nil }
        let (styled, fixes) = fixStyle(fixTop(c, app: app))
        let (text, copies) = removeMenuCopies(styled, menu: menu)
        var findings = PackLint.lint(Data(text.utf8))
        let keys = blocks(text).filter { $0.name == "keys" }.count
        if findings.allSatisfy({ $0.level != .error }) && keys < minKeys { findings.append(LintFinding(level: .warning, message: fewKeys(keys))) }
        return Outcome(text: text.hasSuffix("\n") ? text : text + "\n", styleFixes: fixes, menuCopies: copies, keyCount: keys, findings: findings)
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
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent(PackStarter.id(id) + (draft ? ".toml.draft" : ".toml"))
        if fm.fileExists(atPath: f.path) {
            var n = 1, bak: URL
            repeat { bak = URL(fileURLWithPath: f.path + ".bak" + (n == 1 ? "" : "\(n)")); n += 1 } while fm.fileExists(atPath: bak.path)
            try fm.copyItem(at: f, to: bak)
        }
        try text.write(to: f, atomically: true, encoding: .utf8)
        return f
    }

    // MARK: buttons

    public enum Action: Equatable, Sendable { case copy, openAI, onDevice }

    /// Copy Prompt always; Send to OpenAI when Use OpenAI is on; Send to On-Device Model when Use On-Device Model is on
    /// and its model can run.
    public static func actions(_ c: LLMConfig, onDeviceReady: Bool) -> [Action] {
        [.copy] + (c.openai ? [.openAI] : []) + (c.onDevice && onDeviceReady ? [.onDevice] : [])
    }

    /// The line under the prompt that tells what it contains.
    public static func contents(menuCount: Int) -> String {
        "This prompt contains the app name, version, bundle id, \(menuCount) menu shortcut\(menuCount == 1 ? "" : "s") and your URLs. "
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
