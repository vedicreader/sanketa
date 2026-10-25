import Foundation
import SanketaCore

/// What Return and ⌥Return do for a vault document, from its `source`, its shelf and its id.
public enum VaultLinks {
    /// ramabana's config folder: memory and learned files
    public static let ramabanaConfig = "~/.config/ramabana"

    /// What Return opens: a web page, a file on this Mac, or, with `abhyasa` (the base URL, nil when abhyasa is off or
    /// does not answer), a concept at `/c/<slug>` and any other document at `/v/<shelf>/<doc_id>`. nil: Return shows
    /// all the text in the panel.
    public static func open(_ source: String, shelf: String? = nil, doc: String? = nil, abhyasa: URL?,
                            exists: (String) -> Bool = FileManager.default.fileExists) -> URL? {
        let concept = "learning://concept/"
        if source.hasPrefix(concept) {
            let slug = String(source.dropFirst(concept.count))
            guard let abhyasa, safe(slug) else { return nil }
            return abhyasa.appendingPathComponent("c").appendingPathComponent(slug)
        }
        if let u = URL(string: source), let s = u.scheme?.lowercased(), s == "http" || s == "https" || s == "file" {
            if s == "file" ? exists(u.path) : u.host != nil { return u }
        } else {
            let p = (source as NSString).expandingTildeInPath
            if p.hasPrefix("/") && exists(p) { return URL(fileURLWithPath: p) }
        }
        guard let abhyasa, let shelf, let doc, safe(shelf), safe(doc) else { return nil }
        return abhyasa.appendingPathComponent("v").appendingPathComponent(shelf).appendingPathComponent(doc)
    }

    /// What ⌥Return does: resume `ramabana://session/<id>`, or open the file of `ramabana://memory/<id>`,
    /// `ramabana://learned/AGENTS.md` or `ramabana://learned/skills/<name>` when it exists. nil: nothing.
    public static func alt(_ source: String, config: String = ramabanaConfig,
                           exists: (String) -> Bool = FileManager.default.fileExists) -> VaultAlt? {
        let pre = "ramabana://"
        guard source.hasPrefix(pre) else { return nil }
        let parts = source.dropFirst(pre.count).split(separator: "/").map(String.init)
        guard parts.allSatisfy(safe) else { return nil }
        let root = (config as NSString).expandingTildeInPath
        let file: String
        switch parts.count {
        case 2 where parts[0] == "session": return .resume(parts[1])
        case 2 where parts[0] == "memory": file = "\(root)/memory/\(parts[1])/MEMORY.md"
        case 2 where parts == ["learned", "AGENTS.md"]: file = "\(root)/learned/AGENTS.md"
        case 3 where parts[0] == "learned" && parts[1] == "skills": file = "\(root)/learned/skills/\(parts[2])/SKILL.md"
        default: return nil
        }
        return exists(file) ? .file(URL(fileURLWithPath: file)) : nil
    }

    /// Letters, digits, `-`, `_` and `.`, and not only dots: safe in a path and in a shell word.
    static func safe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && !s.allSatisfy { $0 == "." }
    }
}

/// Tells if abhyasa answers on this Mac: `GET <base>/health`, with a short timeout. The answer is kept for `keep`
/// seconds, so a search asks at most once in that time.
public final class AbhyasaProbe: @unchecked Sendable {
    public let base: URL
    let keep: TimeInterval
    let check: @Sendable (URL) async -> Bool
    let lock = NSLock()
    var last: (at: Date, up: Bool)?

    public init(base: URL, keep: TimeInterval = 10, timeout: TimeInterval = 0.3, check: (@Sendable (URL) async -> Bool)? = nil) {
        self.base = base; self.keep = keep
        self.check = check ?? { u in
            var r = URLRequest(url: u.appendingPathComponent("health"), timeoutInterval: timeout)
            r.httpMethod = "GET"
            let c = URLSessionConfiguration.ephemeral
            c.connectionProxyDictionary = [:]
            let s = URLSession(configuration: c)
            defer { s.finishTasksAndInvalidate() }
            guard let (_, resp) = try? await s.data(for: r) else { return false }
            return (resp as? HTTPURLResponse)?.statusCode == 200
        }
    }

    /// The base URL when abhyasa answers; else nil.
    public func up() async -> URL? {
        if let l = lock.withLock({ last }), Date().timeIntervalSince(l.at) < keep { return l.up ? base : nil }
        let ok = await check(base)
        lock.withLock { last = (Date(), ok) }
        return ok ? base : nil
    }
}
