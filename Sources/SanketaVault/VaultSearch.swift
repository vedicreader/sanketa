import Foundation
import Adhara
import SanketaCore

/// Keyword search over every shelf of a vishalakshi vault: one SQLite file that Python writes. Shelf `X` has the chunk
/// table `X`, its FTS5 table `X_fts` and the documents `X_docs`; the main shelf `store` keeps its documents in `docs`.
/// The vault opens read-only, on the first search, and Sanketa never writes to it. Swift has no query encoder, so the
/// search is keyword-only. No vault or a bad vault gives no results and no error.
public final class VaultSearch: VaultSearching, @unchecked Sendable {
    public let path: String
    let learningURL: URL?
    /// results from each shelf, after one result per document
    let perShelf: Int
    /// no new shelf starts after this; a shelf that runs is not stopped
    let budget: TimeInterval
    /// the connection lives on this queue only
    let queue = DispatchQueue(label: "dev.sanketa.vault", qos: .userInitiated)
    var db: Database?

    public init(path: String, learningURL: String = VaultConfig().learningURL, perShelf: Int = 3, budget: TimeInterval = 0.15) {
        self.path = path; self.learningURL = URL(string: learningURL); self.perShelf = perShelf; self.budget = budget
    }

    /// Test shelves that tools leave behind.
    static let junk = ["tmp", "dialogprobe"]
    /// The shelf heading in search: the main shelf is "vault".
    static func label(_ shelf: String) -> String { shelf == "store" ? "vault" : shelf }

    /// The vault's searchable shelves: a chunk table with its FTS5 table and its docs table. `learning` and the main
    /// shelf come first, then the rest by name.
    public static func shelves(_ db: Database) throws -> [String] {
        let names = Set(try db.query("select name from sqlite_master where type = 'table'").compactMap { r -> String? in
            if case .text(let s) = r["name"] { return s }; return nil
        })
        let first = ["learning", "store"]
        return names.compactMap { n -> String? in
            let shelf = n == "docs" ? "store" : n.hasSuffix("_docs") ? String(n.dropLast(5)) : nil
            guard let shelf, shelf.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
                  !junk.contains(where: shelf.hasPrefix), names.contains(shelf), names.contains(shelf + "_fts") else { return nil }
            return shelf
        }.sorted { a, b in
            let (ia, ib) = (first.firstIndex(of: a) ?? first.count, first.firstIndex(of: b) ?? first.count)
            return ia != ib ? ia < ib : a < b
        }
    }

    /// The query words that FTS5 gets: two letters or more, as prefixes.
    static func words(_ q: String) -> [String] {
        q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 }
    }

    public func search(_ query: String) async -> [SearchItem] {
        await withCheckedContinuation { k in queue.async { k.resume(returning: self.run(query)) } }
    }

    /// The search itself, on the caller's thread; `search` calls it on `queue`.
    func run(_ query: String) -> [SearchItem] {
        let start = Date()
        let ws = Self.words(query)
        guard let fts = anyOf(ws), let db = open(), let shelves = try? Self.shelves(db) else { return [] }
        var out: [SearchItem] = []
        for s in shelves {
            if Date().timeIntervalSince(start) > budget { break }
            out += (try? items(db, shelf: s, fts: fts, words: ws)) ?? []
        }
        return out
    }

    /// The connection, opened on first use; a missing file is tried again on the next search.
    func open() -> Database? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path), let d = try? Database(path: path, readonly: true) else { return nil }
        try? d.exec("pragma busy_timeout = 50")
        db = d
        return d
    }

    /// The best `perShelf` documents of one shelf, best first: one chunk for each document.
    func items(_ db: Database, shelf: String, fts: String, words: [String]) throws -> [SearchItem] {
        let hits = try db.search(store: shelf, fts: fts, vector: nil, k: perShelf * 4)
        guard !hits.isEmpty else { return [] }
        let docs = shelf == "store" ? "docs" : "\(shelf)_docs"
        let rows = try db.query("""
            select s.rowid as rid, s.content, s.heading, s.doc_id, d.title, d.source, d.kind
            from [\(shelf)] s left join [\(docs)] d on d.id = s.doc_id
            where s.rowid in (\(hits.map { String($0.id) }.joined(separator: ",")))
            """)
        func text(_ r: [String: Value], _ k: String) -> String? { if case .text(let s) = r[k], !s.isEmpty { return s }; return nil }
        let byID = Dictionary(rows.compactMap { r -> (Int64, [String: Value])? in
            if case .int(let id) = r["rid"] { return (id, r) }; return nil
        }) { a, _ in a }
        var seen = Set<String>(), out: [SearchItem] = []
        for h in hits {
            guard out.count < perShelf, let r = byID[h.id] else { continue }
            let content = text(r, "content") ?? ""
            let title = text(r, "title") ?? text(r, "heading") ?? Self.firstLine(content)
            guard seen.insert(text(r, "doc_id") ?? title).inserted, seen.insert("title:" + title).inserted else { continue }
            let source = text(r, "source")
            var i = SearchItem(packID: "vault:\(shelf)", packName: Self.label(shelf), kind: .vault, title: title,
                               detail: Self.snippet(content, words), explain: source, tags: [text(r, "kind")].compactMap { $0 })
            i.open = source.flatMap { Self.target($0, learningURL: learningURL) }
            out.append(i)
        }
        return out
    }

    /// What Return opens for a document `source`: a concept's page in abhyasa, a web page, or a file that exists.
    /// nil: Return copies the snippet.
    public static func target(_ source: String, learningURL: URL?, exists: (String) -> Bool = FileManager.default.fileExists) -> URL? {
        let concept = "learning://concept/"
        if source.hasPrefix(concept) {
            let slug = String(source.dropFirst(concept.count))
            guard let learningURL, !slug.isEmpty, slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            return learningURL.appendingPathComponent("c").appendingPathComponent(slug)
        }
        if let u = URL(string: source), let s = u.scheme?.lowercased() {
            if s == "http" || s == "https" { return u.host == nil ? nil : u }
            if s == "file" { return exists(u.path) ? u : nil }
        }
        let p = (source as NSString).expandingTildeInPath
        return p.hasPrefix("/") && exists(p) ? URL(fileURLWithPath: p) : nil
    }

    static func firstLine(_ s: String) -> String {
        String(s.split(whereSeparator: \.isNewline).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.prefix(80) ?? "")
    }

    /// About `width` characters of `text` on one line, from a little before the first query word.
    static func snippet(_ text: String, _ words: [String], width: Int = 160) -> String {
        let flat = text.prefix(20_000).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let hit = words.lazy.compactMap { flat.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }.first
        let start = hit.map { flat.index($0.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex } ?? flat.startIndex
        let cut = flat[start...].prefix(width)
        return (start > flat.startIndex ? "…" : "") + cut + (cut.endIndex < flat.endIndex ? "…" : "")
    }
}
