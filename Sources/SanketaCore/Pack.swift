import Foundation

public struct KeyEntry: Codable, Hashable {
    public var keys: String
    public var action: String
    public var group: String?
    public var command: String?
    /// false for a menu item that is currently disabled; nil means enabled
    public var enabled: Bool?
    /// the pack context this key belongs to; overrides the contexts' `groups`
    public var context: String?
    /// true for a live tmux binding whose title is its raw command: it never goes to a remote model
    public var staysOnMac: Bool?
    public init(keys: String, action: String, group: String? = nil, command: String? = nil, enabled: Bool? = nil,
                context: String? = nil, staysOnMac: Bool? = nil) {
        self.keys = keys; self.action = action; self.group = group; self.command = command; self.enabled = enabled
        self.context = context; self.staysOnMac = staysOnMac
    }
}

public struct Tip: Codable, Hashable {
    public var title: String
    public var snippet: String
    public var explain: String
    public var tags: [String]
    /// the pack context this tip belongs to
    public var context: String?
    public init(title: String, snippet: String, explain: String, tags: [String] = [], context: String? = nil) {
        self.title = title; self.snippet = snippet; self.explain = explain; self.tags = tags; self.context = context
    }

    enum CodingKeys: String, CodingKey { case title, snippet, explain, tags, context }

    /// `explain` and `tags` may be left out; a hand- or LLM-written tip shouldn't sink its pack.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        snippet = try c.decode(String.self, forKey: .snippet)
        explain = try c.decodeIfPresent(String.self, forKey: .explain) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        context = try c.decodeIfPresent(String.self, forKey: .context)
    }
}

public enum PackMode: String, Codable { case extend, replace }

/// A view of an app (a pane, a mode) with its own keys: the scope tokens in the window title that select it,
/// and the key groups that belong to it.
public struct PackContext: Codable, Hashable {
    public var name: String
    public var scopes: [String]
    public var groups: [String]
    public init(name: String, scopes: [String] = [], groups: [String] = []) {
        self.name = name; self.scopes = scopes; self.groups = groups
    }

    enum CodingKeys: String, CodingKey { case name, scopes, groups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
    }
}

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
    /// regex on the focused window title; capture group 1 is the scope token that picks a context
    public var titleScope: String?
    public var contexts: [PackContext]
    /// regexes on the window title of a `titleApps` app (a browser) that host this pack's app
    public var titles: [String]
    public var titleApps: [String]
    /// True only for a pack read from TOML (bundled or user), and so for its live tmux merge. Only its entries
    /// may go to a remote model; packs made in code (menu keys) stay false.
    public var fromTOML = false

    public static let browsers = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"]

    public init(id: String, name: String, processes: [String] = [], match: [String] = [], apps: [String] = [],
                prefix: String? = nil, mode: PackMode = .extend, keys: [KeyEntry] = [], tips: [Tip] = [],
                titleScope: String? = nil, contexts: [PackContext] = [], titles: [String] = [], titleApps: [String] = browsers) {
        self.id = id; self.name = name; self.processes = processes; self.match = match; self.apps = apps
        self.prefix = prefix; self.mode = mode; self.keys = keys; self.tips = tips
        self.titleScope = titleScope; self.contexts = contexts; self.titles = titles; self.titleApps = titleApps
    }

    enum CodingKeys: String, CodingKey {
        case id, name, processes, match, apps, prefix, mode, keys, tips, contexts, titles
        case titleScope = "title_scope", titleApps = "title_apps"
    }

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
        titleScope = try c.decodeIfPresent(String.self, forKey: .titleScope)
        contexts = try c.decodeIfPresent([PackContext].self, forKey: .contexts) ?? []
        titles = try c.decodeIfPresent([String].self, forKey: .titles) ?? []
        titleApps = try c.decodeIfPresent([String].self, forKey: .titleApps) ?? Self.browsers
        fromTOML = true
    }
}

extension Pack {
    static func firstMatch(_ pattern: String, _ s: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    /// The scope token that `titleScope` captures from `title`; nil without a regex, a match or a group 1.
    public func scopeToken(title: String?) -> String? {
        guard let title, let re = titleScope, let m = Self.firstMatch(re, title), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: title) else { return nil }
        return String(title[r])
    }

    /// The first context whose `scopes` has the title's token. A scope `editor` also takes `editor:md`.
    public func activeContext(title: String?) -> PackContext? {
        guard let t = scopeToken(title: title) else { return nil }
        let base = String(t.prefix { $0 != ":" })
        return contexts.first { $0.scopes.contains(t) } ?? contexts.first { $0.scopes.contains(base) }
    }

    /// True when key `k` belongs to context `name`: by its own `context`, else by the context's `groups`.
    /// A group may be in more than one context.
    public func key(_ k: KeyEntry, isIn name: String) -> Bool {
        if let c = k.context { return c == name }
        return k.group.map { g in contexts.contains { $0.name == name && $0.groups.contains(g) } } ?? false
    }

    /// True when tip `t` belongs to context `name`: by its own `context`, else by a tag equal to the name or a scope.
    public func tip(_ t: Tip, isIn name: String) -> Bool {
        if let c = t.context { return c == name }
        let tags = Set(t.tags.map { $0.lowercased() })
        return contexts.contains { c in c.name == name && ([c.name] + c.scopes).contains { tags.contains($0.lowercased()) } }
    }

    /// True when a browser window with `title` shows this pack's app.
    public func hosted(in bundleID: String, title: String?) -> Bool {
        guard let title, titleApps.contains(bundleID) else { return false }
        return titles.contains { Self.firstMatch($0, title) != nil }
    }
}
