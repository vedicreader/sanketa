import Foundation

/// An app's keymap file, `<keymaps folder>/<app>.json`: the app writes it from the table that drives its own keys and
/// help. Format 1 has `version`, `app`, `name`, `written_by`, `written_at`, `contexts` (`id` and `label`, listed once)
/// and `keys`: rows with `action`, `chords` (Leela's grammar, one or a list), `label`, `group`, and optional `context`
/// (an id or a list; none means any time), `range` ("1-9", its chords listed in full) and `command` (typed text, not chords).
/// Sanketa only reads these files; it never writes them.
public struct AppKeymap: Equatable, Sendable {
    public struct Context: Equatable, Sendable {
        public var id: String
        public var label: String
    }

    public struct Row: Equatable, Sendable {
        public var action: String
        /// in Mac symbols, alternatives joined by " / "; a range is "⌥1…9"
        public var keys: String
        public var label: String
        public var group: String?
        /// the context ids of the row; empty means any time
        public var contexts: [String]
        /// typed text, such as `/peers`
        public var command: Bool
    }

    public var app: String
    public var name: String
    public var writtenBy: String?
    public var contexts: [Context]
    public var rows: [Row]
    /// rows that had no action, chords or label
    public var skipped = 0

    public static let formats: Set<Int> = [1]
    /// the group of the rows that have no context
    public static let anyTime = "Any time"

    /// `$SANKETA_KEYMAPS` when set, else `<home>/.config/sanketa/keymaps`.
    public static func folder(env: [String: String] = ProcessInfo.processInfo.environment, home: URL) -> URL {
        env["SANKETA_KEYMAPS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config/sanketa/keymaps", isDirectory: true)
    }

    public enum ReadError: Error, Equatable {
        case notJSON, noApp, version(String?)
        public var message: String {
            switch self {
            case .notJSON: "Sanketa cannot read this file. It must be a JSON object with a keys list"
            case .noApp: "This file has no app name"
            case .version(let v): v.map { "Sanketa does not know keymap format \($0)" } ?? "This file has no keymap format version"
            }
        }
    }

    /// One file. A row without an action, chords or a label is skipped and counted in `skipped`.
    public static func parse(_ data: Data, hyperLabel: String = "Caps") throws -> AppKeymap {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ReadError.notJSON }
        let version = obj["version"]
        guard let version, !isBool(version), let v = version as? Int, formats.contains(v) else {
            throw ReadError.version(obj["version"].map(shown))
        }
        guard let app = (obj["app"] as? String)?.trimmingCharacters(in: .whitespaces), !app.isEmpty else { throw ReadError.noApp }
        guard let keys = obj["keys"] as? [Any] else { throw ReadError.notJSON }
        let contexts = (obj["contexts"] as? [Any] ?? []).compactMap { c -> Context? in
            guard let d = c as? [String: Any], let id = d["id"] as? String, !id.isEmpty else { return nil }
            return Context(id: id, label: (d["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id)
        }
        var m = AppKeymap(app: app, name: obj["name"] as? String ?? app, writtenBy: obj["written_by"] as? String, contexts: contexts, rows: [])
        for k in keys {
            guard let d = k as? [String: Any], let action = d["action"] as? String, let label = d["label"] as? String, !label.isEmpty,
                  case let chords = strings(d["chords"]), !chords.isEmpty else { m.skipped += 1; continue }
            let command = d["command"] as? Bool ?? false
            m.rows.append(Row(action: action, keys: render(chords, range: d["range"] != nil, command: command, hyperLabel: hyperLabel),
                              label: label, group: d["group"] as? String, contexts: strings(d["context"]), command: command))
        }
        return m
    }

    /// A JSON value as the note shows it: text in quotes, null as null.
    static func shown(_ v: Any) -> String {
        if let s = v as? String { return "\"\(s)\"" }
        if v is NSNull { return "null" }
        if isBool(v) { return (v as? Bool) == true ? "true" : "false" }
        return "\(v)"
    }

    /// JSON true or false, which Foundation also gives as the numbers 1 and 0.
    static func isBool(_ v: Any) -> Bool { CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }

    /// A string or a list of strings; anything else gives none.
    static func strings(_ v: Any?) -> [String] {
        if let s = v as? String { return s.isEmpty ? [] : [s] }
        return (v as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// Chords in Mac symbols: typed text stays as written; a range shows as its first chord, "…" and the last key ("⌥1…9").
    public static func render(_ chords: [String], range: Bool = false, command: Bool = false, hyperLabel: String = "Caps") -> String {
        if command { return chords.joined(separator: " / ") }
        let shown = chords.map { LeelaKeymap.render($0, hyperLabel: hyperLabel) }
        guard range, shown.count > 1, let first = shown.first, let last = shown.last else { return shown.joined(separator: " / ") }
        let hyper = hyperLabel + "\u{a0}", end = last.hasPrefix(hyper) ? last.dropFirst(hyper.count) : Substring(last)
        return first + "…" + String(end.drop { Modifier(rawValue: String($0)) != nil })
    }

    /// The rows as pack keys, grouped by context: the rows for any time first, then each context with its label (a row with
    /// two contexts shows in both), then the typed commands that have no context, in their own groups.
    public var entries: [KeyEntry] {
        func entry(_ r: Row, _ group: String?, _ context: String?) -> KeyEntry {
            KeyEntry(keys: r.keys, action: r.label, group: group, context: context)
        }
        let labels = Dictionary(contexts.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        // a context that a row names but the list leaves out still gets a group, after the listed ones
        var order = contexts.map(\.id)
        for c in rows.flatMap(\.contexts) where !order.contains(c) { order.append(c) }
        let any = rows.filter { $0.contexts.isEmpty && !$0.command }.map { entry($0, Self.anyTime, nil) }
        let inContexts = order.flatMap { c in rows.filter { $0.contexts.contains(c) }.map { entry($0, labels[c] ?? c, c) } }
        let typed = rows.filter { $0.contexts.isEmpty && $0.command }.map { entry($0, $0.group, nil) }
        return any + inContexts + typed
    }

    /// One pack context for each context: the window title's token is its id, and the rows for any time are in each.
    public var packContexts: [PackContext] {
        var ids = contexts.map(\.id)
        for c in rows.flatMap(\.contexts) where !ids.contains(c) { ids.append(c) }
        return ids.map { PackContext(name: $0, scopes: [$0], groups: [Self.anyTime]) }
    }

    /// `pack` with this file's keys and contexts. The pack keeps its processes, title rules and tips. With no `title_scope`
    /// of its own, the pack reads the context from a window title such as "ramabana · running".
    public func apply(to pack: Pack, file: URL) -> Pack {
        var p = pack
        p.keys = entries
        p.contexts = packContexts.map { c in
            var c = c
            if let own = pack.contexts.first(where: { $0.name == c.name }) { c.scopes += own.scopes.filter { !c.scopes.contains($0) } }
            return c
        }
        if p.titleScope == nil { p.titleScope = Self.titleScope(app: app) }
        p.keymap = file.path
        return p
    }

    /// The window-title rule for an app's context: the app name, " · ", then the context id.
    public static func titleScope(app: String) -> String {
        "(?:^|[^A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: app) + " · ([a-z][a-z0-9_]*)"
    }

    /// Reads every `*.json` file in `folder` and gives its keys to the pack whose id is the file's `app`. A file that
    /// cannot be read, has an unknown format or names no pack is skipped with one note; that pack keeps its own keys.
    public static func apply(to lib: inout PackLibrary, folder: URL?, hyperLabel: String = "Caps") {
        guard let folder else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for f in files {
            let own = f.deletingPathExtension().lastPathComponent
            func note(_ m: String) { lib.errors.append(PackLoadError(file: f.path, message: m)) }
            guard let data = try? Data(contentsOf: f) else { continue }   // gone or half written: the next change reads it
            do {
                let m = try parse(data, hyperLabel: hyperLabel)
                guard let pack = lib.packs[m.app] else { note("No pack has the id \(m.app). Sanketa does not use this file"); continue }
                lib.packs[m.app] = m.apply(to: pack, file: f)
                if m.skipped > 0 { note("Sanketa skipped \(m.skipped) \(m.skipped == 1 ? "row" : "rows") with no action, chords or label") }
            } catch let e as ReadError {
                note(e.message + (lib.packs[own].map { ". It uses the keys of the \($0.name) pack" } ?? ""))
            } catch { continue }
        }
    }

    /// The toast after a keymap file changed: the packs whose keys are new, or nil when no keys changed.
    public static func readNote(old: PackLibrary, new: PackLibrary) -> String? {
        let changed = new.packs.values.filter { $0.keymap != nil && old.packs[$0.id]?.keys != $0.keys }.map(\.name).sorted()
        guard !changed.isEmpty else { return nil }
        return "Sanketa read the new keys of \(changed.joined(separator: ", "))."
    }
}
