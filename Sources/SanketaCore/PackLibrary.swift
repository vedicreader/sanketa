import Foundation
import TOMLDecoder

public struct PackLoadError: Hashable {
    public var file: String
    public var message: String
    public init(file: String, message: String) { self.file = file; self.message = message }
}

public struct PackLibrary {
    public var packs: [String: Pack] = [:]
    public var errors: [PackLoadError] = []

    public init(packs: [String: Pack] = [:], errors: [PackLoadError] = []) {
        self.packs = packs; self.errors = errors
    }

    public static func decode(_ data: Data) throws -> Pack {
        try TOMLDecoder().decode(Pack.self, from: data)
    }

    /// Loads bundled packs, then merges user packs over them by `id`; bad files are skipped and reported.
    public static func load(bundled: URL, user: URL?) -> PackLibrary {
        var lib = PackLibrary()
        for dir in [bundled, user].compactMap({ $0 }) {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "toml" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for f in files {
                do {
                    let p = try decode(Data(contentsOf: f))
                    lib.packs[p.id] = lib.packs[p.id].map { merge($0, p) } ?? p
                } catch {
                    lib.errors.append(PackLoadError(file: f.path, message: PackLint.describe(error)))
                }
            }
        }
        return lib
    }

    public static func merge(_ base: Pack, _ overlay: Pack) -> Pack {
        if overlay.mode == .replace { return overlay }
        var m = base
        m.name = overlay.name
        m.prefix = overlay.prefix ?? base.prefix
        m.processes = union(base.processes, overlay.processes)
        m.match = union(base.match, overlay.match)
        m.apps = union(base.apps, overlay.apps)
        m.keys = overlaying(base.keys, overlay.keys, by: \.keys)
        m.tips = overlaying(base.tips, overlay.tips, by: \.title)
        m.titleScope = overlay.titleScope ?? base.titleScope
        m.contexts = overlaying(base.contexts, overlay.contexts, by: \.name)
        m.titles = union(base.titles, overlay.titles)
        m.titleApps = union(base.titleApps, overlay.titleApps)
        return m
    }

    static func union(_ a: [String], _ b: [String]) -> [String] { a + b.filter { !a.contains($0) } }

    static func overlaying<T>(_ base: [T], _ over: [T], by key: KeyPath<T, String>) -> [T] {
        let new = Dictionary(over.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { $1 })
        let kept = base.map { new[$0[keyPath: key]] ?? $0 }
        let have = Set(base.map { $0[keyPath: key] })
        var seen = Set<String>()
        return kept + over.filter { !have.contains($0[keyPath: key]) && seen.insert($0[keyPath: key]).inserted }
    }

    /// argv `match` first, then the process name, then argv[0]'s basename (what the user typed;
    /// Claude Code's executable is `…/versions/2.1.304` but argv[0] is `claude`).
    public func pack(process name: String, argv: [String]) -> Pack? { pick(process: name, argv: argv)?.pack }

    /// The pack for a process and the rule that picked it: `match "bin/ramabana"`, `process htop` or `argv[0] claude`.
    public func pick(process name: String, argv: [String]) -> (pack: Pack, reason: String)? {
        let sorted = packs.values.sorted { $0.id < $1.id }
        let cmd = argv.joined(separator: " ")
        let typed = argv.first.map { ($0.drop { $0 == "-" } as Substring as NSString).lastPathComponent }
        for p in sorted { if let m = p.match.first(where: { cmd.contains($0) }) { return (p, "match \"\(m)\"") } }
        if let p = sorted.first(where: { $0.processes.contains(name) }) { return (p, "process \(name)") }
        if let t = typed, let p = sorted.first(where: { $0.processes.contains(t) }) { return (p, "argv[0] \(t)") }
        return nil
    }

    public func pack(bundleID: String) -> Pack? {
        packs.values.sorted { $0.id < $1.id }.first { $0.apps.contains(bundleID) }
    }

    /// The pack whose app runs in the browser `bundleID`, found by the window title.
    public func pack(hostedIn bundleID: String, title: String?) -> Pack? {
        packs.values.sorted { $0.id < $1.id }.first { $0.hosted(in: bundleID, title: title) }
    }

    /// What in `title` changes the layers of the app: the pack that it picks (own or hosted) and its scope token.
    /// Nil when the title shows no pack.
    public func titleKey(bundleID: String, title: String?) -> String? {
        let p = pack(bundleID: bundleID) ?? pack(hostedIn: bundleID, title: title)
        return p.map { "\($0.id)|\($0.scopeToken(title: title) ?? "")" }
    }

    /// True when the app's window title can change its layers: a pack reads a scope from it, or a pack may be hosted in it.
    public func readsTitle(bundleID: String) -> Bool {
        pack(bundleID: bundleID)?.titleScope != nil || packs.values.contains { !$0.titles.isEmpty && $0.titleApps.contains(bundleID) }
    }
}
