import Foundation
import TOMLDecoder

/// A TOML value with no schema: tables keep every key, so the lint can see fields the decoder skips.
indirect enum TOMLValue: Decodable {
    case table([String: TOMLValue]), array([TOMLValue]), string(String), other

    struct AnyKey: CodingKey {
        var stringValue: String, intValue: Int? = nil
        init(stringValue s: String) { stringValue = s }
        init?(intValue: Int) { nil }
    }

    /// Scalars first: TOMLDecoder decodes a scalar with its parent's decoder, which would also give a keyed container.
    init(from d: Decoder) throws {
        if let s = try? d.singleValueContainer() {
            self = (try? s.decode(String.self)).map(TOMLValue.string) ?? .other
        } else if let c = try? d.container(keyedBy: AnyKey.self) {
            self = .table(Dictionary(uniqueKeysWithValues: try c.allKeys.map { ($0.stringValue, try c.decode(TOMLValue.self, forKey: $0)) }))
        } else if var u = try? d.unkeyedContainer() {
            var a = [TOMLValue]()
            while !u.isAtEnd { a.append(try u.decode(TOMLValue.self)) }
            self = .array(a)
        } else { self = .other }
    }

    var table: [String: TOMLValue]? { if case .table(let t) = self { t } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [TOMLValue]? { if case .array(let a) = self { a } else { nil } }
}

public struct LintFinding: Hashable, CustomStringConvertible {
    public enum Level: String { case error, warning }
    public var level: Level
    public var message: String
    public var description: String { level == .error ? message : "warning: " + message }
}

/// Checks a pack file against docs/packs.md: schema, key style, duplicates and regexes. Errors make `--lint-pack` fail.
public enum PackLint {
    enum Kind { case string, strings, tables, any }
    typealias Schema = [(name: String, kind: Kind, required: Bool)]

    static let top: Schema = [("id", .string, true), ("name", .string, true), ("processes", .strings, false), ("match", .strings, false),
                              ("apps", .strings, false), ("prefix", .string, false), ("mode", .string, false), ("keys", .tables, false),
                              ("tips", .tables, false), ("title_scope", .string, false), ("contexts", .tables, false),
                              ("titles", .strings, false), ("title_apps", .strings, false)]
    static let key: Schema = [("keys", .string, true), ("action", .string, true), ("group", .string, false), ("command", .string, false),
                              ("context", .string, false), ("enabled", .any, false)]
    static let tip: Schema = [("title", .string, true), ("snippet", .string, true), ("explain", .string, false), ("tags", .strings, false),
                              ("context", .string, false)]
    static let context: Schema = [("name", .string, true), ("scopes", .strings, false), ("groups", .strings, false)]

    /// Words an action may have; the panel is narrow.
    public static let maxActionWords = 6

    public static func lint(file: URL) -> [LintFinding] {
        guard let data = try? Data(contentsOf: file) else { return [LintFinding(level: .error, message: "cannot read the file")] }
        return lint(data)
    }

    public static func lint(_ data: Data) -> [LintFinding] {
        let root: [String: TOMLValue]
        do {
            guard let t = try TOMLDecoder().decode(TOMLValue.self, from: data).table else { return [err("the file is not a TOML table")] }
            root = t
        } catch { return [err(describe(error))] }
        var out = check(root, top, "the pack")
        if let m = root["mode"]?.string, PackMode(rawValue: m) == nil { out.append(err("mode must be extend or replace, not \(m)")) }
        let keys = root["keys"]?.array?.compactMap(\.table) ?? []
        let tips = root["tips"]?.array?.compactMap(\.table) ?? []
        let contexts = root["contexts"]?.array?.compactMap(\.table) ?? []
        let names = Set(contexts.compactMap { $0["name"]?.string })
        let tmuxStyle = root["prefix"] != nil
        var seen = [String: Int]()
        for (i, k) in keys.enumerated() {
            let n = "key \(i + 1)"
            out += check(k, key, n)
            guard let ks = k["keys"]?.string else { continue }
            let label = "\(n) (\(ks))"
            if !tmuxStyle, k["command"] == nil, let fix = styleFix(ks) { out.append(err("\(label): write \(fix)")) }
            let g = k["group"]?.string ?? ""
            // an empty key is a Leela action that the user's keymap fills
            if !ks.isEmpty, let j = seen.updateValue(i, forKey: g + "\u{1}" + ks) {
                out.append(err("\(label): same keys as key \(j + 1)" + (g.isEmpty ? "" : " in group \(g)")))
            }
            if let a = k["action"]?.string, case let n = words(a), n > maxActionWords {
                out.append(warn("\(label): the action has \(n) words. Use \(maxActionWords) or fewer."))
            }
            if let c = k["context"]?.string, !names.contains(c) { out.append(warn("\(label): no context has the name \(c)")) }
        }
        var titles = [String: Int]()
        for (i, t) in tips.enumerated() {
            out += check(t, tip, "tip \(i + 1)")
            if let title = t["title"]?.string, let j = titles.updateValue(i, forKey: title) {
                out.append(warn("tip \(i + 1): same title as tip \(j + 1), so it replaces that tip"))
            }
            if let c = t["context"]?.string, !names.contains(c) { out.append(warn("tip \(i + 1): no context has the name \(c)")) }
        }
        for (i, c) in contexts.enumerated() { out += check(c, context, "context \(i + 1)") }
        if let re = root["title_scope"]?.string {
            if let r = try? NSRegularExpression(pattern: re) {
                if r.numberOfCaptureGroups < 1 { out.append(err("title_scope has no group. Put ( ) around the scope token.")) }
            } else { out.append(err("title_scope is not a valid regex")) }
        }
        for (i, re) in (root["titles"]?.array ?? []).compactMap(\.string).enumerated() where (try? NSRegularExpression(pattern: re)) == nil {
            out.append(err("titles \(i + 1) is not a valid regex"))
        }
        let triggers = ["processes", "match", "apps", "titles"].contains { !(root[$0]?.array ?? []).isEmpty }
        if !triggers { out.append(warn("the pack has no processes, match, apps or titles, so only search shows it")) }
        for (i, m) in (root["match"]?.array ?? []).compactMap(\.string).enumerated() where m.count < 4 {
            out.append(warn("match \(i + 1) (\(m)) is short and can find other programs"))
        }
        return out
    }

    /// Required fields, types and unknown fields of one table.
    static func check(_ t: [String: TOMLValue], _ schema: Schema, _ subject: String) -> [LintFinding] {
        var out = [LintFinding]()
        for f in schema {
            guard let v = t[f.name] else {
                if f.required { out.append(err("\(subject) has no \(f.name)")) }
                continue
            }
            let ok: Bool = switch f.kind {
            case .string: v.string != nil
            case .strings: v.array.map { $0.allSatisfy { $0.string != nil } } ?? false
            case .tables: v.array.map { $0.allSatisfy { $0.table != nil } } ?? false
            case .any: true
            }
            if !ok {
                let what = switch f.kind { case .string: "a string"; case .strings: "a list of strings"; case .tables: "[[\(f.name)]] tables"; case .any: "" }
                out.append(err("\(subject): \(f.name) must be \(what)"))
            }
        }
        let known = schema.map(\.name)
        for k in t.keys.sorted() where !known.contains(k) {
            let near = known.min { distance(k, $0) < distance(k, $1) }.flatMap { distance(k, $0) <= 3 ? $0 : nil }
            out.append(err("\(subject): unknown field \(k)" + (near.map { ". Did you mean \($0)?" } ?? "")))
        }
        return out
    }

    /// The key text in the style of the docs, or nil when it is already in that style.
    public static func styleFix(_ keys: String) -> String? {
        let fixed = keys.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.isEmpty || $0 == "/" ? String($0) : KeyNotation.step(String($0)) }.joined(separator: " ")
        return fixed == keys ? nil : fixed
    }

    /// Words of an action; a `/` between alternatives is not a word.
    static func words(_ s: String) -> Int { s.split(separator: " ").filter { $0 != "/" }.count }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    static func err(_ m: String) -> LintFinding { LintFinding(level: .error, message: m) }
    static func warn(_ m: String) -> LintFinding { LintFinding(level: .warning, message: m) }

    /// A decode error as one short line, such as `key 2 has no action`.
    /// `root` names the top-level table; config.toml passes "" so a line reads `hotkey must be a string`.
    public static func describe(_ error: Error, root: String = "the pack") -> String {
        func subject(_ path: [CodingKey]) -> String {
            var s = root
            for (i, k) in path.enumerated() {
                guard let n = k.intValue else { continue }
                let table = i > 0 ? path[i - 1].stringValue : ""
                s = (["keys": "key", "tips": "tip", "contexts": "context"][table] ?? table) + " \(n + 1)"
            }
            return s
        }
        func at(_ path: [CodingKey]) -> String { subject(path).isEmpty ? "" : subject(path) + ": " }
        func field(_ path: [CodingKey]) -> String? { path.last.flatMap { $0.intValue == nil ? $0.stringValue : nil } }
        switch error {
        case DecodingError.keyNotFound(let k, let c):
            let s = subject(c.codingPath)
            return "\(s.isEmpty ? "the file" : s) has no \(k.stringValue)"
        case DecodingError.typeMismatch(let t, let c), DecodingError.valueNotFound(let t, let c):
            let name = String(describing: t)
            let what = t == String.self ? "a string" : t == [String].self ? "a list of strings"
                : name.contains("Unkeyed") || name.hasPrefix("Array") ? "a list"
                : t == Double.self || t == Int.self ? "a number" : t == Bool.self ? "true or false" : "of another type"
            return field(c.codingPath).map { "\(at(c.codingPath))\($0) must be \(what)" } ?? "\(subject(c.codingPath)) must be \(what)"
        case DecodingError.dataCorrupted(let c):
            if let u = c.underlyingError { return describe(u, root: root) }
            return field(c.codingPath).map { "\(at(c.codingPath))\($0) has a value that is not valid" } ?? "the file is not valid TOML"
        case let e as TOMLError:
            let d = e.description.replacingOccurrences(of: #"Type mismatch at table key '([^']+)': expected (\w+)"#, with: "$1 must be a $2",
                                                       options: .regularExpression)
            guard let re = try? Regex(#"^\(Line (\d+)\) (.)(.*?)\.?$"#), let m = d.firstMatch(of: re),
                  let n = m.output[1].substring, let c = m.output[2].substring, let r = m.output[3].substring else { return d }
            return "line \(n): \(c.lowercased())\(r)"
        default:
            return "\(error)"
        }
    }

    /// `--lint-pack`: findings as `file: message` lines for each `.toml` file in `paths` (files or folders), and the exit status.
    public static func run(_ paths: [String]) -> (lines: [String], status: Int32) {
        var files = [URL]()
        for p in paths {
            let u = URL(fileURLWithPath: p)
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &dir) else { return (["\(p): no such file or folder"], 2) }
            files += dir.boolValue
                ? ((try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "toml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                : [u]
        }
        var lines = [String](), errors = 0, warnings = 0
        for f in files {
            for x in lint(file: f) {
                lines.append("\(f.lastPathComponent): \(x)")
                if x.level == .error { errors += 1 } else { warnings += 1 }
            }
        }
        lines.append("\(files.count) file\(files.count == 1 ? "" : "s"): \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")")
        return (lines, errors > 0 ? 1 : 0)
    }
}
