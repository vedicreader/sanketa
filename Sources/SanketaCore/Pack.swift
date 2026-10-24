import Foundation

public struct KeyEntry: Codable, Hashable {
    public var keys: String
    public var action: String
    public var group: String?
    public var command: String?
    /// false for a menu item that is currently disabled; nil means enabled
    public var enabled: Bool?
    public init(keys: String, action: String, group: String? = nil, command: String? = nil, enabled: Bool? = nil) {
        self.keys = keys; self.action = action; self.group = group; self.command = command; self.enabled = enabled
    }
}

public struct Tip: Codable, Hashable {
    public var title: String
    public var snippet: String
    public var explain: String
    public var tags: [String]
    public init(title: String, snippet: String, explain: String, tags: [String] = []) {
        self.title = title; self.snippet = snippet; self.explain = explain; self.tags = tags
    }

    enum CodingKeys: String, CodingKey { case title, snippet, explain, tags }

    /// `explain` and `tags` may be left out; a hand- or LLM-written tip shouldn't sink its pack.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        snippet = try c.decode(String.self, forKey: .snippet)
        explain = try c.decodeIfPresent(String.self, forKey: .explain) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

public enum PackMode: String, Codable { case extend, replace }

public struct Pack: Codable, Hashable {
    public var id: String
    public var name: String
    public var processes: [String]
    public var match: [String]
    public var apps: [String]
    public var prefix: String?
    public var mode: PackMode
    public var keys: [KeyEntry]
    public var tips: [Tip]

    public init(id: String, name: String, processes: [String] = [], match: [String] = [], apps: [String] = [],
                prefix: String? = nil, mode: PackMode = .extend, keys: [KeyEntry] = [], tips: [Tip] = []) {
        self.id = id; self.name = name; self.processes = processes; self.match = match; self.apps = apps
        self.prefix = prefix; self.mode = mode; self.keys = keys; self.tips = tips
    }

    enum CodingKeys: String, CodingKey { case id, name, processes, match, apps, prefix, mode, keys, tips }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        processes = try c.decodeIfPresent([String].self, forKey: .processes) ?? []
        match = try c.decodeIfPresent([String].self, forKey: .match) ?? []
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
        mode = try c.decodeIfPresent(PackMode.self, forKey: .mode) ?? .extend
        keys = try c.decodeIfPresent([KeyEntry].self, forKey: .keys) ?? []
        tips = try c.decodeIfPresent([Tip].self, forKey: .tips) ?? []
    }
}
