import Foundation

/// One better way that history shows, with how often and how lately it would have helped.
public struct Coaching: Hashable, Sendable {
    public var detectorID: String
    public var title: String
    public var shell: Shell
    public var before: String
    public var after: String
    public var explain: String
    public var count: Int
    public var lastSeen: Date?

    public var item: SearchItem {
        SearchItem(packID: "coach", packName: "Better ways", kind: .suggestion, title: title, detail: after,
                   explain: "Instead of \(before) · \(count)× in your history. \(explain)", tags: ["coach", detectorID, shell.rawValue])
    }
}

public enum Coach {
    public typealias Hit = (detectorID: String, title: String, rewrite: Rewrite)

    /// For each command of `line`, the rewrite of the first detector that has one.
    public static func rewrites(_ line: String, shell: Shell) -> [Hit] {
        ShellLex.commands(line, shell: shell).compactMap { c in
            guard !c.stages.joined().contains(where: \.isRedirect) else { return nil }
            var c = c
            c.text = droppingKeywords(c.text, shell)
            for d in Detectors.all where d.shells.contains(shell) {
                if let r = d.rewrite(c, shell) { return (d.id, d.title, r) }
            }
            return nil
        }
    }

    /// One result per detector and shell that fired, most frequent first, then most recent.
    public static func analyze(_ entries: [HistoryEntry]) -> [Coaching] {
        struct Key: Hashable { var id: String; var shell: Shell }
        struct Acc { var hit: Hit; var count: Int; var when: Date? }
        var cache: [Shell: [String: [Hit]]] = [:], acc: [Key: Acc] = [:]
        for e in entries {
            let hits = cache[e.shell, default: [:]][e.command] ?? {
                let h = rewrites(e.command, shell: e.shell)
                cache[e.shell, default: [:]][e.command] = h
                return h
            }()
            var seen = Set<String>()
            for h in hits where seen.insert(h.detectorID).inserted {
                let k = Key(id: h.detectorID, shell: e.shell)
                guard var a = acc[k] else { acc[k] = Acc(hit: h, count: 1, when: e.when); continue }
                a.count += 1
                // dated hits rank above undated ones; among undated ones the later line wins
                if let w = e.when { if a.when.map({ w >= $0 }) ?? true { a.hit = h; a.when = w } }
                else if a.when == nil { a.hit = h }
                acc[k] = a
            }
        }
        let order = Dictionary(uniqueKeysWithValues: Detectors.all.enumerated().map { ($0.element.id, $0.offset) })
        return acc.map { k, a in
            Coaching(detectorID: k.id, title: a.hit.title, shell: k.shell, before: a.hit.rewrite.before, after: a.hit.rewrite.after,
                     explain: a.hit.rewrite.explain, count: a.count, lastSeen: a.when)
        }.sorted { x, y in
            if x.count != y.count { return x.count > y.count }
            if x.lastSeen != y.lastSeen { return (x.lastSeen ?? .distantPast) > (y.lastSeen ?? .distantPast) && x.lastSeen != nil }
            if x.detectorID != y.detectorID { return order[x.detectorID, default: 0] < order[y.detectorID, default: 0] }
            return x.shell.rawValue < y.shell.rawValue
        }
    }

    /// `text` without the leading keywords (`time`, `and`, `do` …) that the lexer drops from the stages.
    static func droppingKeywords(_ text: String, _ shell: Shell) -> String {
        let kw = ShellLex.keywords[shell] ?? []
        var t = Substring(text)
        while let sp = t.firstIndex(where: { $0 == " " || $0 == "\t" }), kw.contains(String(t[..<sp])) {
            t = t[sp...].drop(while: { $0 == " " || $0 == "\t" })
        }
        return String(t)
    }
}
