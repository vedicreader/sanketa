import Foundation

/// `vault`: a document from a shelf of the vishalakshi vault, found by `VaultSearching`
public enum ItemKind: String, Codable, Sendable { case key, tip, suggestion, vault }

/// What ⌥Return does on a vault result: resume a ramabana session, or open the file of a ramabana memory entry.
public enum VaultAlt: Hashable, Sendable {
    case resume(String)
    case file(URL)
}

public struct SearchItem: Hashable, Identifiable, Sendable {
    public var packID: String
    public var packName: String
    public var kind: ItemKind
    public var title: String
    public var detail: String
    public var explain: String?
    public var tags: [String]
    /// in the active context of its layer; ranks higher
    public var active = false
    /// may go to a remote model: set only for entries of TOML packs and live tmux keys
    public var mayLeave = false
    /// a key's command, for copy; it stays on the Mac
    public var command: String?
    /// what Return opens instead of a copy, such as a vault document's web page or file
    public var open: URL?
    /// what ⌥Return does, for some vault results
    public var alt: VaultAlt?
    public var id: String { "\(packID)|\(kind.rawValue)|\(title)" }

    public init(packID: String, packName: String, kind: ItemKind, title: String, detail: String,
                explain: String? = nil, tags: [String] = [], mayLeave: Bool = false, command: String? = nil) {
        self.packID = packID; self.packName = packName; self.kind = kind; self.title = title
        self.detail = detail; self.explain = explain; self.tags = tags; self.mayLeave = mayLeave; self.command = command
    }

    /// The text the user types: a tip's snippet or a key's command. A key with no command has nothing to copy.
    public var copyText: String? { kind == .key ? command.flatMap { $0.isEmpty ? nil : $0 } : detail }

    /// The pack's keys and tips; with `context`, those in that pack context are `active`.
    public static func items(from p: Pack, context: String? = nil) -> [SearchItem] {
        func mark(_ i: SearchItem, _ on: Bool) -> SearchItem { var i = i; i.active = on; return i }
        return p.keys.map { k in mark(SearchItem(packID: p.id, packName: p.name, kind: .key, title: k.action, detail: k.keys,
                                                 mayLeave: p.fromTOML && k.staysOnMac != true, command: k.command),
                                      context.map { p.key(k, isIn: $0) } ?? false) }
        + p.tips.map { t in mark(SearchItem(packID: p.id, packName: p.name, kind: .tip, title: t.title, detail: t.snippet,
                                            explain: t.explain, tags: t.tags, mayLeave: p.fromTOML), context.map { p.tip(t, isIn: $0) } ?? false) }
    }
}

public protocol SearchProviding {
    func results(_ query: String, _ items: [SearchItem], context: [String]) -> [SearchItem]
}

/// Search outside the packs, such as the vishalakshi vault. It runs off the main thread; it gives no results on error.
public protocol VaultSearching: Sendable {
    func search(_ query: String) async -> [SearchItem]
}

/// Saves a note in the vishalakshi vault, through Python. Only a user action calls it. It gives the saved title.
public protocol VaultWriting: Sendable {
    func save(text: String, title: String) async throws -> String
}

public struct LocalSearch: SearchProviding {
    public init() {}
    public func results(_ query: String, _ items: [SearchItem], context: [String]) -> [SearchItem] {
        Search.rank(query, items, context: context)
    }
}

public enum Search {
    static func tokens(_ q: String) -> [String] { q.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }

    static func isSubsequence(_ t: String, of s: String) -> Bool {
        var it = s.makeIterator()
        return t.allSatisfy { c in while let x = it.next() { if x == c { return true } }; return false }
    }

    static func tokenScore(_ t: String, _ item: SearchItem) -> Int? {
        let title = item.title.lowercased()
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(t) }) { return 30 }
        if title.contains(t) { return 20 }
        if ([item.detail, item.packName] + item.tags).contains(where: { $0.lowercased().contains(t) }) { return 10 }
        return isSubsequence(t, of: title) ? 3 : nil
    }

    /// Bonus for an item in its layer's active context: one match level, so a better match elsewhere still wins.
    static let activeBonus = 10

    public static func score(_ query: String, _ item: SearchItem) -> Int? {
        var total = item.active ? activeBonus : 0
        for t in tokens(query) {
            guard let s = tokenScore(t, item) else { return nil }
            total += s
        }
        return total
    }

    /// A fuzzy result (a word found only as letters in order in the title) must score at least this share of the
    /// top score. Matches in the title, keys, tags or pack name always stay.
    public static let floor = 0.5

    /// True when some word of the query matches the item only as a subsequence of its title.
    static func fuzzy(_ query: String, _ item: SearchItem) -> Bool { tokens(query).contains { tokenScore($0, item) == 3 } }

    /// `context` is pack ids, innermost first; context packs sort ahead of the rest, then by score.
    public static func rank(_ query: String, _ items: [SearchItem], context: [String], limit: Int = 50) -> [SearchItem] {
        let rankOf = { (i: SearchItem) in context.firstIndex(of: i.packID) ?? Int.max }
        var scored: [(i: Int, item: SearchItem, score: Int)]
        if tokens(query).isEmpty {
            scored = items.enumerated().filter { rankOf($0.element) != .max }.map { ($0.offset, $0.element, $0.element.active ? activeBonus : 0) }
        } else {
            scored = items.enumerated().compactMap { o in score(query, o.element).map { (o.offset, o.element, $0) } }
            let top = Double(scored.map(\.score).max() ?? 0)
            scored.removeAll { Double($0.score) < top * floor && fuzzy(query, $0.item) }
        }
        return scored.sorted { a, b in
            let (ra, rb) = (rankOf(a.item), rankOf(b.item))
            if ra != rb { return ra < rb }
            if a.score != b.score { return a.score > b.score }
            return a.i < b.i
        }.prefix(limit).map(\.item)
    }
}
