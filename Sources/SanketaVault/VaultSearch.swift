import Foundation
import Adhara
import SanketaCore

/// Keyword search over every shelf of a vishalakshi vault: one SQLite file that Python writes. Shelf `X` has the chunk
/// table `X`, its FTS5 table `X_fts` and the documents `X_docs`; the main shelf `store` keeps its documents in `docs`.
/// The vault opens read-only, on the first search, and Sanketa never writes to it. Swift has no query encoder, so the
/// search is keyword-only. No vault or a bad vault gives no results and no error.
public final class VaultSearch: VaultSearching, @unchecked Sendable {
    public let path: String
    /// abhyasa, when `[abhyasa]` is on: Return opens documents there while it answers
    let probe: AbhyasaProbe?
    /// results from each shelf, after one result per document
    let perShelf: Int
    /// no new shelf starts after this; a shelf that runs is not stopped
    let budget: TimeInterval
    /// the connection lives on this queue only
    let queue = DispatchQueue(label: "dev.sanketa.vault", qos: .userInitiated)
    var db: Database?

    public init(path: String, abhyasa: AbhyasaProbe? = nil, perShelf: Int = 3, budget: TimeInterval = 0.15) {
        self.path = path; self.probe = abhyasa; self.perShelf = perShelf; self.budget = budget
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

    public func search(_ query: String) async -> [SearchItem] { await search(query, shelf: perShelf) }

    /// A quarter of `limit` from each shelf, and never fewer than `perShelf`.
    public func search(_ query: String, limit: Int) async -> [SearchItem] { await search(query, shelf: max(perShelf, limit / 4)) }

    func search(_ query: String, shelf n: Int) async -> [SearchItem] {
        guard !Self.words(query).isEmpty else { return [] }
        let abhyasa = await probe?.up()
        return await withCheckedContinuation { k in queue.async { k.resume(returning: self.run(query, abhyasa: abhyasa, perShelf: n)) } }
    }

    /// The search itself, on the caller's thread; `search` calls it on `queue`. `abhyasa`: the base URL when it answers.
    /// `perShelf`: nil for `self.perShelf`.
    func run(_ query: String, abhyasa: URL? = nil, perShelf n: Int? = nil) -> [SearchItem] {
        let start = Date()
        let ws = Self.words(query)
        guard let fts = anyOf(ws), let db = open(), let shelves = try? Self.shelves(db) else { return [] }
        var out: [SearchItem] = []
        for s in shelves {
            if Date().timeIntervalSince(start) > budget { break }
            out += (try? items(db, shelf: s, fts: fts, words: ws, abhyasa: abhyasa, perShelf: n ?? perShelf)) ?? []
        }
        return out
    }

    /// `f` with the read-only connection, on `queue`; nil when there is no vault.
    func withDB<T>(_ f: @escaping (Database) -> T?) async -> T? {
        await withCheckedContinuation { k in queue.async { k.resume(returning: self.open().flatMap(f)) } }
    }

    /// The connection, opened on first use; a missing file is tried again on the next search.
    func open() -> Database? {
        if let db { return db }
        guard FileManager.default.fileExists(atPath: path), let d = try? Database(path: path, readonly: true) else { return nil }
        try? d.exec("pragma busy_timeout = 50")
        db = d
        return d
    }

    /// The best `perShelf` documents of one shelf, best first: one chunk for each document. `n`: nil for `self.perShelf`.
    func items(_ db: Database, shelf: String, fts: String, words: [String], abhyasa: URL? = nil, perShelf n: Int? = nil) throws -> [SearchItem] {
        let perShelf = n ?? self.perShelf
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
            let doc = text(r, "doc_id")
            guard seen.insert(doc ?? title).inserted, seen.insert("title:" + title).inserted else { continue }
            out.append(Self.item(shelf: shelf, doc: doc, title: title, detail: Self.snippet(content, words), source: text(r, "source"),
                                 kind: text(r, "kind"), abhyasa: abhyasa))
        }
        return out
    }

    /// One vault result, with what Return and ⌥Return do.
    static func item(shelf: String, doc: String?, title: String, detail: String, source: String?, kind: String?, abhyasa: URL?) -> SearchItem {
        var i = SearchItem(packID: "vault:\(shelf)", packName: label(shelf), kind: .vault, title: title, detail: detail,
                           explain: source, tags: [kind].compactMap { $0 })
        i.open = VaultLinks.open(source ?? "", shelf: shelf, doc: doc, abhyasa: abhyasa)
        i.alt = source.flatMap { VaultLinks.alt($0) }
        return i
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
