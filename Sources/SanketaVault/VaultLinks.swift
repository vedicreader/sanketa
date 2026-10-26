import Foundation
import SanketaCore

/// Where vault results open in abhyasa: the installed Mac app, through `abhyasa://` links, or a server at `base`.
public enum AbhyasaTarget: Equatable, Sendable {
    case app
    case web(URL)

    /// `abhyasa://a/b/c` for the app, `<base>/x/y/z` for a server. Each part must be `VaultLinks.safe`.
    func link(_ app: [String], web: [String]) -> URL? {
        switch self {
        case .app: return URL(string: "abhyasa://" + app.joined(separator: "/"))
        case .web(let base): return web.reduce(base) { $0.appendingPathComponent($1) }
        }
    }
}

/// What Return and ⌥Return do for a vault document, from its `source`, its shelf and its id.
public enum VaultLinks {
    /// ramabana's config folder: memory and learned files
    public static let ramabanaConfig = "~/.config/ramabana"

    /// What Return opens: a web page, a file on this Mac, or a link to abhyasa. With `.app` (Abhyasa.app is installed), a
    /// concept opens `abhyasa://concept/<slug>` and any other document `abhyasa://vault/<shelf>/<doc_id>`: these work on any
    /// port and start the app. With `.web(base)` (a server answers), they open `<base>/c/<slug>` and `<base>/v/<shelf>/<doc_id>`.
    /// nil: Return shows all the text in the panel.
    public static func open(_ source: String, shelf: String? = nil, doc: String? = nil, abhyasa: AbhyasaTarget?,
                            exists: (String) -> Bool = FileManager.default.fileExists) -> URL? {
        let concept = "learning://concept/"
        if source.hasPrefix(concept) {
            let slug = String(source.dropFirst(concept.count))
            guard let abhyasa, safe(slug) else { return nil }
            return abhyasa.link(["concept", slug], web: ["c", slug])
        }
        if let u = page(source, exists: exists) { return u }
        guard let abhyasa, let shelf, let doc, safe(shelf), safe(doc) else { return nil }
        return abhyasa.link(["vault", shelf, doc], web: ["v", shelf, doc])
    }

    /// The web page or the file on this Mac that `source` names; nil: none.
    public static func page(_ source: String, exists: (String) -> Bool = FileManager.default.fileExists) -> URL? {
        if let u = URL(string: source), let s = u.scheme?.lowercased(), s == "http" || s == "https" || s == "file" {
            return (s == "file" ? exists(u.path) : u.host != nil) ? u : nil
        }
        let p = (source as NSString).expandingTildeInPath
        return p.hasPrefix("/") && exists(p) ? URL(fileURLWithPath: p) : nil
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

    /// ⌥Return for a document with no web page and no file, such as a note saved with ⌘S: open its text as a Markdown
    /// file. nil: it has a page or a file, or its shelf or id is not safe.
    public static func markdown(_ source: String, shelf: String, doc: String?,
                                exists: (String) -> Bool = FileManager.default.fileExists) -> VaultAlt? {
        guard let doc, safe(shelf), safe(doc), page(source, exists: exists) == nil else { return nil }
        return .markdown(shelf: shelf, doc: doc)
    }

    /// Letters, digits, `-`, `_` and `.`, and not only dots: safe in a path and in a shell word.
    static func safe(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } && !s.allSatisfy { $0 == "." }
    }
}

/// Finds where vault results open in abhyasa. When Abhyasa.app is installed (`app` says so), it is `.app` and no request
/// goes out. Else, with a `base`, it asks `GET <base>/health` with a short timeout, and keeps the answer for `keep` seconds,
/// so a search asks at most once in that time.
public final class AbhyasaProbe: @unchecked Sendable {
    public let base: URL?
    let keep: TimeInterval
    let app: @Sendable () -> Bool
    let check: @Sendable (URL) async -> Bool
    let lock = NSLock()
    var last: (at: Date, up: Bool)?

    public init(base: URL?, app: @escaping @Sendable () -> Bool = { false }, keep: TimeInterval = 10, timeout: TimeInterval = 0.3,
                check: (@Sendable (URL) async -> Bool)? = nil) {
        self.base = base; self.app = app; self.keep = keep
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

    /// `.app` when the app is installed, else `.web(base)` when the server answers; else nil.
    public func up() async -> AbhyasaTarget? {
        if app() { return .app }
        guard let base else { return nil }
        if let l = lock.withLock({ last }), Date().timeIntervalSince(l.at) < keep { return l.up ? .web(base) : nil }
        let ok = await check(base)
        lock.withLock { last = (Date(), ok) }
        return ok ? .web(base) : nil
    }

    /// What `up` would give now, with no request: the app, or the last answer of the server. nil: not known, or no.
    public var cached: AbhyasaTarget? {
        if app() { return .app }
        guard let base, let l = lock.withLock({ last }), l.up else { return nil }
        return .web(base)
    }
}
