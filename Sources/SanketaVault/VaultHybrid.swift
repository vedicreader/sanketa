import Foundation
import Adhara
import SanketaCore

/// Hybrid search (words and meaning) over every shelf of the vault, and notes saved to it, through vishalakshi's MCP
/// server. Search calls `federate`, which fuses the shelves by rank (RRF). Swift has no query encoder, and Python does
/// all writes. When the server is not ready, fails or is slow, search gives the keyword results of `keyword`, and a
/// search that finds the server not ready starts it for the next one.
public final class VaultHybrid: VaultSearching, VaultWriting, @unchecked Sendable {
    public let keyword: VaultSearch
    public let client: MCPClient
    /// the most time that one hybrid search can take
    let timeout: TimeInterval
    /// the most time that a save can take, after the server started
    let saveTimeout: TimeInterval
    /// fused hits asked for
    let limit: Int

    public init(keyword: VaultSearch, client: MCPClient, timeout: TimeInterval = 1, saveTimeout: TimeInterval = 30, limit: Int = 10) {
        self.keyword = keyword; self.client = client; self.timeout = timeout; self.saveTimeout = saveTimeout; self.limit = limit
    }

    /// The MCP client for `[vault]`: the server at `mcp_url` (on this Mac only), else a child from `mcp_command` on the
    /// same vault file. nil: `mcp` is off, or there is no server to use.
    public static func client(for c: VaultConfig, exists: (String) -> Bool = FileManager.default.isExecutableFile) -> MCPClient? {
        guard c.enabled, c.mcp else { return nil }
        if !c.mcpURL.isEmpty {
            guard let u = URL(string: c.mcpURL), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
                  ["127.0.0.1", "localhost", "::1"].contains(u.host?.lowercased() ?? "") else { return nil }
            return MCPClient(idle: 0) { HTTPTransport(url: u) }
        }
        guard let cmd = c.resolvedCommand(exists: exists) else { return nil }
        let vault = c.resolvedPath()
        return MCPClient(idle: c.mcpIdleSeconds) { try StdioTransport(command: cmd, environment: ["VISHALAKSHI_VAULT": vault]) }
    }

    /// The search for `[vault]`: hybrid when an MCP server can be used, else keyword only. nil: vault search is off.
    public static func make(_ c: VaultConfig, abhyasa: AbhyasaConfig = AbhyasaConfig()) -> (search: VaultSearching, writer: VaultWriting?)? {
        guard c.enabled else { return nil }
        let k = VaultSearch(path: c.resolvedPath(), abhyasa: abhyasa.base.map { AbhyasaProbe(base: $0) })
        guard let m = client(for: c) else { return (k, nil) }
        let h = VaultHybrid(keyword: k, client: m, timeout: c.mcpTimeoutSeconds)
        return (h, h)
    }

    public func search(_ query: String) async -> [SearchItem] { await search(query, limit: limit) }

    /// `limit` fused hits; the keyword search, when it is used, gives a quarter of `limit` from each shelf.
    public func search(_ query: String, limit: Int) async -> [SearchItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = VaultSearch.words(q)
        guard !words.isEmpty else { return [] }
        guard client.isReady else { client.warm(); return await keyword.search(q, limit: limit) }
        let shelves = await keyword.withDB { db in try? Self.searchable(db) } ?? []
        do {
            let r = try await client.call("federate", ["q": q, "limit": limit, "repo": false, "grep": false, "env": false,
                                                       "shelves": shelves.filter { $0 != "store" }], timeout: timeout)
            guard let hits = (r.first as? [String: Any])?["hits"] as? [[String: Any]] else { throw MCPError.protocolError("no hits") }
            return await items(hits, words: words, abhyasa: keyword.probe?.up())
        } catch {
            return await keyword.search(q, limit: limit)
        }
    }

    /// The shelves to search: those of `VaultSearch.shelves` that have a document.
    static func searchable(_ db: Database) throws -> [String] {
        try VaultSearch.shelves(db).filter { s in
            !(try db.query("select 1 as one from [\(s == "store" ? "docs" : "\(s)_docs")] limit 1")).isEmpty
        }
    }

    /// The shelf of a fused hit: `prose` is the main shelf, `shelf:X` is X.
    static func shelf(_ source: String) -> String? {
        if source == "prose" { return "store" }
        guard source.hasPrefix("shelf:") else { return nil }
        let s = String(source.dropFirst(6))
        return s.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil ? nil : s
    }

    /// Fused hits as vault results, in RRF rank: one for each document. Search ranks them with the pack results.
    func items(_ hits: [[String: Any]], words: [String], abhyasa: URL? = nil) async -> [SearchItem] {
        struct Hit { let shelf, doc, title, text: String }
        let hs = hits.compactMap { h -> Hit? in
            guard let shelf = (h["source"] as? String).flatMap(Self.shelf), let ref = h["ref"] as? String else { return nil }
            let doc = String(ref.split(separator: "#").first ?? "")
            return Hit(shelf: shelf, doc: doc, title: h["title"] as? String ?? "", text: h["text"] as? String ?? "")
        }
        // the document's title, source and kind, from the vault file: a hit's own title can be "Pages 1–1: …"
        let pairs = Set(hs.map { "\($0.shelf)\u{1}\($0.doc)" })
        let docs = await keyword.withDB { db -> [String: (String?, String?, String?)] in
            var out: [String: (String?, String?, String?)] = [:]
            for p in pairs {
                let (s, d) = (String(p.split(separator: "\u{1}")[0]), String(p.split(separator: "\u{1}").dropFirst().first ?? ""))
                let t = s == "store" ? "docs" : "\(s)_docs"
                guard let r = try? db.query("select title, source, kind from [\(t)] where id = ?", [.text(d)]).first
                else { continue }
                func text(_ k: String) -> String? { if case .text(let v) = r[k], !v.isEmpty { return v }; return nil }
                out[p] = (text("title"), text("source"), text("kind"))
            }
            return out
        } ?? [:]
        var seen = Set<String>(), out: [SearchItem] = []
        for h in hs {
            let (docTitle, source, kind) = docs["\(h.shelf)\u{1}\(h.doc)"] ?? (nil, nil, nil)
            let title = docTitle ?? (h.title.isEmpty ? VaultSearch.firstLine(h.text) : h.title)
            guard seen.insert("\(h.shelf)/\(h.doc)").inserted, seen.insert("\(h.shelf)|\(title)").inserted else { continue }
            out.append(VaultSearch.item(shelf: h.shelf, doc: h.doc, title: title, detail: VaultSearch.snippet(h.text, words),
                                        source: source, kind: kind, abhyasa: abhyasa))
        }
        return out
    }

    /// Saves `text` as a note on the main shelf, with the tag `sanketa`. Each save is a new note: its key is new, so
    /// it never replaces a note with the same title.
    public func save(text: String, title: String) async throws -> String {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MCPError.tool("nothing to save") }
        let t = Self.title(title.isEmpty ? body : title)
        let key = "sanketa-" + UUID().uuidString.prefix(12).lowercased()
        _ = try await client.call("note", ["text": body, "title": t, "tags": ["sanketa"], "key": key,
                                           "meta": ["from": "sanketa"]], timeout: saveTimeout, force: true)
        return t
    }

    /// The first line that is not empty, cut to 80 characters.
    static func title(_ s: String) -> String {
        let l = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return l.count > 80 ? String(l.prefix(79)) + "…" : l
    }
}
