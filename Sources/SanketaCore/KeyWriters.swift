import Foundation
import TOMLDecoder

/// Why a key change was not written.
public enum KeyWriteError: Error, Equatable, LocalizedError {
    case notJSON, noKeysObject, notFound(String), changedSince(String), changedBefore(String), unsupportedKey(String), inUse(String), sameKey,
         notHotkey(String), notTOML

    public var errorDescription: String? {
        switch self {
        case .notJSON: "keys.json is not valid JSON. Sanketa did not change it."
        case .noKeysObject: "keys.json has no \"keys\" part. Sanketa did not change it."
        case .notFound(let x): "Sanketa did not find \(x) in the file."
        case .inUse(let x): "\(x) is in use in AeroSpace. Sanketa did not change the file."
        case .changedSince: "The file changed after the change. Undo did not run, so your edit stays."
        case .changedBefore: "The file changed after Sanketa read it. Sanketa did not change it."
        case .unsupportedKey(let x): "Leela cannot use the key \(x). Sanketa did not change the file."
        case .sameKey: "The new key is the same as the old key. Sanketa did not change the file."
        case .notHotkey(let x): "Sanketa cannot use \(x) as a hotkey. Use one or more modifier keys with a letter, a digit, Space, F1 to F12, or / . ,. Sanketa did not change the file."
        case .notTOML: "config.toml is not valid TOML. Sanketa did not change it."
        }
    }
}

/// Edits the top-level `keys` object of Leela's keys.json as text, so every other byte stays.
public enum LeelaKeysWriter {
    public static func change(_ text: String, action: String, live: String, from: Chord, to: Chord) throws -> String {
        guard from != to else { throw KeyWriteError.sameKey }
        guard let new = to.leelaText else { throw KeyWriteError.unsupportedKey(to.display()) }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw KeyWriteError.notJSON }
        guard let keys = root["keys"] as? [String: Any] else { throw KeyWriteError.noKeysObject }
        let b = Array(text.utf8), members = try members(b, of: "keys")
        func swap(_ v: String) throws -> String {
            var parts = v.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            // compare chords, not spellings: "shift+alt+b" and "N" (shift+n) are written by hand too
            guard let i = parts.firstIndex(where: { Chord.leela($0) == from }) else { throw KeyWriteError.notFound(from.leelaText ?? from.display()) }
            parts[i] = new
            return parts.joined(separator: " ")
        }
        var out = b
        if let cur = keys[action] {
            guard let old = cur as? String else { throw KeyWriteError.notFound(action) }
            guard let m = members.items.first(where: { $0.name == action }), m.value.count >= 2 else { throw KeyWriteError.notFound(action) }
            out.replaceSubrange(m.value, with: Array(literal(try swap(old)).utf8))
        } else {
            let entry = "\(literal(action)): \(literal(try swap(live)))"
            if let last = members.items.last {
                let ind = indent(b, before: last.start) ?? indent(b, before: members.keyStart).map { $0 + "  " } ?? "  "
                out.insert(contentsOf: Array(",\n\(ind)\(entry)".utf8), at: last.value.upperBound)
            } else {
                let ind = indent(b, before: members.keyStart) ?? ""
                out.replaceSubrange(members.open + 1..<members.close, with: Array("\n\(ind)  \(entry)\n\(ind)".utf8))
            }
        }
        let result = String(decoding: out, as: UTF8.self)
        guard (try? JSONSerialization.jsonObject(with: Data(result.utf8))) != nil else { throw KeyWriteError.notJSON }
        return result
    }

    struct Member { var name: String; var start: Int; var value: Range<Int> }
    struct Members { var keyStart: Int; var open: Int; var close: Int; var items: [Member] }

    static func literal(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    /// The whitespace from the start of the line to `i`, when only whitespace lies between; else nil.
    static func indent(_ b: [UInt8], before i: Int) -> String? {
        var s = i
        while s > 0, b[s - 1] != 10 { s -= 1 }
        let w = b[s..<i]
        return w.allSatisfy { $0 == 32 || $0 == 9 } && s > 0 ? String(decoding: w, as: UTF8.self) : nil
    }

    /// The end (exclusive) of the string literal that starts at `i`.
    static func stringEnd(_ b: [UInt8], _ i: Int) -> Int {
        var p = i + 1
        while p < b.count, b[p] != 34 { p += b[p] == 92 ? 2 : 1 }
        return min(p + 1, b.count)
    }

    /// The end (exclusive) of the JSON value that starts at `i`.
    static func valueEnd(_ b: [UInt8], _ i: Int) -> Int {
        var p = i, depth = 0
        while p < b.count {
            switch b[p] {
            case 34: p = stringEnd(b, p); if depth == 0 { return p }; continue
            case 123, 91: depth += 1
            case 125, 93: if depth == 0 { return p }; depth -= 1; if depth == 0 { return p + 1 }
            case 44 where depth == 0: return p
            default: if depth == 0, [32, 10, 13, 9].contains(b[p]) { return p }
            }
            p += 1
        }
        return p
    }

    static func skipSpace(_ b: [UInt8], _ i: Int) -> Int {
        var p = i
        while p < b.count, [32, 10, 13, 9].contains(b[p]) { p += 1 }
        return p
    }

    /// The members of the object that is the value of top-level member `name`.
    static func members(_ b: [UInt8], of name: String) throws -> Members {
        var p = skipSpace(b, 0)
        guard p < b.count, b[p] == 123 else { throw KeyWriteError.notJSON }
        p = skipSpace(b, p + 1)
        while p < b.count, b[p] == 34 {
            let ks = p, e = stringEnd(b, p), k = String(decoding: b[p + 1..<e - 1], as: UTF8.self)
            p = skipSpace(b, e)
            guard p < b.count, b[p] == 58 else { break }
            let v = skipSpace(b, p + 1), ve = valueEnd(b, v)
            if k == name {
                guard b[v] == 123 else { throw KeyWriteError.noKeysObject }
                var items = [Member](), q = skipSpace(b, v + 1)
                while q < b.count, b[q] == 34 {
                    let ke = stringEnd(b, q), mk = String(decoding: b[q + 1..<ke - 1], as: UTF8.self)
                    let vs = skipSpace(b, skipSpace(b, ke) + 1), mve = valueEnd(b, vs)
                    items.append(Member(name: mk, start: q, value: vs..<mve))
                    q = skipSpace(b, mve)
                    if q < b.count, b[q] == 44 { q = skipSpace(b, q + 1) }
                }
                return Members(keyStart: ks, open: v, close: ve - 1, items: items)
            }
            p = skipSpace(b, ve)
            if p < b.count, b[p] == 44 { p = skipSpace(b, p + 1) }
        }
        throw KeyWriteError.noKeysObject
    }
}

/// Edits the left side of one binding line of an AeroSpace config.
public enum AeroSpaceWriter {
    public static func change(_ text: String, mode: String, from: Chord, to: Chord) throws -> String {
        guard from != to else { throw KeyWriteError.sameKey }
        let bindings = AeroSpaceConfig.parse(text).modes[mode] ?? []
        guard let b = bindings.first(where: { $0.chord == from }) else { throw KeyWriteError.notFound(from.aerospaceText) }
        if bindings.contains(where: { $0.chord == to }) { throw KeyWriteError.inUse(to.aerospaceText) }
        // find the line exactly as the parser does (every Character that isNewline ends a line), and edit it in place
        var start = text.startIndex, n = 1
        while n < b.line, let nl = text[start...].firstIndex(where: \.isNewline) { start = text.index(after: nl); n += 1 }
        guard n == b.line else { throw KeyWriteError.notFound(from.aerospaceText) }
        let end = text[start...].firstIndex(where: \.isNewline) ?? text.endIndex, line = text[start..<end]
        let lead = line.prefix { $0 == " " || $0 == "\t" }, rest = line.dropFirst(lead.count)
        let quote = rest.first.flatMap { $0 == "'" || $0 == "\"" ? $0 : nil }
        let key = quote != nil ? rest.dropFirst().prefix { $0 != quote } : rest.prefix { $0 != "=" && $0 != " " && $0 != "\t" }
        guard Chord.aerospace(String(key)) == from else { throw KeyWriteError.notFound(from.aerospaceText) }
        let q = quote.map(String.init) ?? "", keyEnd = line.index(rest.startIndex, offsetBy: key.count + 2 * q.count)
        var out = text
        out.replaceSubrange(rest.startIndex..<keyEnd, with: q + to.aerospaceText + q)
        return out
    }

    static let hookPrefix = "exec-and-forget open -g 'sanketa://aerospace/mode/"

    static func isSafeName(_ n: String) -> Bool {
        !n.isEmpty && n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Makes each binding that runs `mode X` also run `exec-and-forget open -g 'sanketa://aerospace/mode/X'`, once; every other byte stays.
    public static func addModeHook(_ text: String) -> String {
        var chars = Array(text)
        var starts = [0]
        for (i, c) in chars.enumerated() where c.isNewline { starts.append(i + 1) }
        var edits = [(range: Range<Int>, text: String)]()
        for b in AeroSpaceConfig.parse(text).modes.values.joined() {
            guard b.line <= starts.count,
                  let name = b.commands.reversed().lazy.compactMap({ c -> String? in
                      let w = c.split(whereSeparator: \.isWhitespace)
                      return w.count == 2 && w[0] == "mode" && isSafeName(String(w[1])) ? String(w[1]) : nil
                  }).first else { continue }
            let hook = hookPrefix + name + "'"
            guard !b.commands.contains(hook), var p = valueStart(chars, from: starts[b.line - 1]) else { continue }
            let q = "\"\(hook)\""
            if chars[p] == "[" {
                var last: Int?, old: Range<Int>?
                p += 1
                scan: while p < chars.count {
                    switch chars[p] {
                    case "]": break scan
                    case "#": while p < chars.count, !chars[p].isNewline { p += 1 }
                    case "'", "\"":
                        let s = p
                        p = stringEnd(chars, p); last = p
                        if String(chars[s + 1..<max(s + 1, p - 1)]).hasPrefix(hookPrefix) { old = s..<p }
                    default: p += 1
                    }
                }
                guard p < chars.count, let last else { continue }
                if let old { edits.append((old, q)) } else { edits.append((last..<last, ", " + q)) }
            } else if chars[p] == "'" || chars[p] == "\"" {
                edits.append((p..<p, "["))
                edits.append((stringEnd(chars, p)..<stringEnd(chars, p), ", " + q + "]"))
            }
        }
        for e in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) { chars.replaceSubrange(e.range, with: e.text) }
        return String(chars)
    }

    /// Where the value of the binding on the line that starts at `i` begins.
    static func valueStart(_ a: [Character], from i: Int) -> Int? {
        var p = i
        while p < a.count, a[p] == " " || a[p] == "\t" { p += 1 }
        if p < a.count, a[p] == "'" || a[p] == "\"" { p = stringEnd(a, p) }
        while p < a.count, !a[p].isNewline, a[p] != "=" { p += 1 }
        guard p < a.count, a[p] == "=" else { return nil }
        p += 1
        while p < a.count, a[p] == " " || a[p] == "\t" { p += 1 }
        return p < a.count ? p : nil
    }

    /// The end (exclusive) of the TOML string that starts at `i`.
    static func stringEnd(_ a: [Character], _ i: Int) -> Int {
        let c = a[i], triple = i + 2 < a.count && a[i + 1] == c && a[i + 2] == c
        var p = i + (triple ? 3 : 1)
        while p < a.count {
            if c == "\"", a[p] == "\\" { p += 2; continue }
            if a[p] == c, !triple || (p + 2 < a.count && a[p + 1] == c && a[p + 2] == c) { return min(p + (triple ? 3 : 1), a.count) }
            if !triple, a[p].isNewline { return p }
            p += 1
        }
        return a.count
    }

    public static let reloadCandidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace", "~/.local/bin/aerospace"]

    /// The reload command line with the first aerospace that `exists`; nil: none.
    public static func reloadCommand(exists: (String) -> Bool = FileManager.default.isExecutableFile) -> [String]? {
        reloadCandidates.map { ($0 as NSString).expandingTildeInPath }.first(where: exists).map { [$0, "reload-config"] }
    }
}

/// Edits only the value of the top-level `hotkey = "…"` line of Sanketa's config.toml, so every other byte stays. With no
/// such line, it adds one before the first table.
public enum SanketaConfigWriter {
    public static func change(_ text: String, to new: Chord) throws -> String {
        guard let value = new.hotkeyText else { throw KeyWriteError.notHotkey(new.display()) }
        guard let now = try? TOMLDecoder().decode(Config.self, from: Data(text.utf8)) else { throw KeyWriteError.notTOML }
        guard Chord.hotkey(now.hotkey) != new else { throw KeyWriteError.sameKey }
        let b = Array(text.utf8), quoted = Array("\"\(value)\"".utf8)
        let nl: [UInt8] = text.contains("\r\n") ? [13, 10] : [10], line = Array("hotkey = ".utf8) + quoted + nl
        func skip(_ i: Int, _ end: Int) -> Int { var p = i; while p < end, b[p] == 32 || b[p] == 9 { p += 1 }; return p }
        var out: [UInt8]?, start = 0
        while out == nil, start < b.count {
            let end = b[start...].firstIndex(of: 10) ?? b.count, p = skip(start, end)
            if p < end, b[p] == 91 { out = Array(b[..<start]) + line + Array(b[start...]); break }   // [
            let name = Array("hotkey".utf8)
            if end - p > name.count, Array(b[p..<p + name.count]) == name {
                var q = skip(p + name.count, end)
                if q < end, b[q] == 61 {   // =
                    q = skip(q + 1, end)
                    if q < end, b[q] == 34 || b[q] == 39 {
                        var e = q + 1
                        while e < end, b[e] != b[q] { e += b[q] == 34 && b[e] == 92 ? 2 : 1 }
                        if e < end { out = Array(b[..<q]) + quoted + Array(b[(e + 1)...]) }
                    }
                    if out == nil { throw KeyWriteError.notTOML }
                }
            }
            start = end + 1
        }
        let result = String(decoding: out ?? (b + (b.isEmpty || b.last == 10 ? [] : nl) + line), as: UTF8.self)
        guard (try? TOMLDecoder().decode(Config.self, from: Data(result.utf8)))?.hotkey == value else { throw KeyWriteError.notTOML }
        return result
    }
}

/// One change of one file: the text before and after, and the command that makes the app read it.
public struct KeyChange: Sendable {
    public var file: URL
    public var before: String
    public var after: String
    public var reload: [String]?
    public init(file: URL, before: String, after: String, reload: [String]?) { self.file = file; self.before = before; self.after = after; self.reload = reload }
}

/// Writes a change with a backup, and undoes it only when the file is still as the change left it.
public final class KeyChangeStore {
    let runner: CommandRunning, fm: FileManager
    public init(runner: CommandRunning, fileManager: FileManager = .default) { self.runner = runner; fm = fileManager }

    /// Refuses with `.changedBefore` when the file is not as `before`. Returns true when the reload ran or none was needed; false: the file is changed but the reload failed.
    public func apply(_ c: KeyChange) throws -> Bool {
        guard let now = try? Data(contentsOf: c.file), now == Data(c.before.utf8) else { throw KeyWriteError.changedBefore(c.file.path) }
        try write(c.before, to: URL(fileURLWithPath: c.file.path + ".sanketa-bak"), like: c.file)
        try write(c.after, to: c.file, like: c.file)
        return reload(c)
    }

    /// Same result as `apply`.
    public func undo(_ c: KeyChange) throws -> Bool {
        guard let now = try? Data(contentsOf: c.file), now == Data(c.after.utf8) else { throw KeyWriteError.changedSince(c.file.path) }
        try write(c.before, to: c.file, like: c.file)
        return reload(c)
    }

    func reload(_ c: KeyChange) -> Bool {
        guard let r = c.reload, let path = r.first else { return true }
        return runner.run(path, Array(r.dropFirst()), timeout: 10) != nil
    }

    /// Writes `text` atomically to `url` (through a symlink), with the permissions of `like`.
    func write(_ text: String, to url: URL, like: URL) throws {
        let perms = (try? fm.attributesOfItem(atPath: like.resolvingSymlinksInPath().path))?[.posixPermissions]
        let target = url.resolvingSymlinksInPath()
        try text.write(to: target, atomically: true, encoding: .utf8)
        if let perms { try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path) }
    }
}
