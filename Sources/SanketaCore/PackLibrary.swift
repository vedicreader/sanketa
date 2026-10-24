import Foundation
import TOMLDecoder

public struct PackLoadError: Hashable {
    public var file: String
    public var message: String
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
                    lib.errors.append(PackLoadError(file: f.path, message: "\(error)"))
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

    public func pack(process name: String, argv: [String]) -> Pack? {
        let sorted = packs.values.sorted { $0.id < $1.id }
        let cmd = argv.joined(separator: " ")
        return sorted.first { $0.match.contains { cmd.contains($0) } }
            ?? sorted.first { $0.processes.contains(name) }
    }

    public func pack(bundleID: String) -> Pack? {
        packs.values.sorted { $0.id < $1.id }.first { $0.apps.contains(bundleID) }
    }
}
