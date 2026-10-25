import AppKit
import Combine
import SanketaCore
import SanketaSystem

/// Query → ranked results over the library plus context packs, with a clamped selection. For 3 or more words, a model
/// may move its picks to the top after the user stops typing for `debounce` seconds. For 3 or more letters, vault results
/// come after the pack results, `vaultDebounce` seconds after the user stops typing.
@MainActor public final class SearchModel: ObservableObject {
    @Published public var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published public private(set) var results: [SearchItem] = []
    @Published public private(set) var selection = 0
    /// ids of the results that the model chose
    @Published public private(set) var picked: Set<String> = []
    /// the result that shows all its text, by id; one at a time
    @Published public private(set) var expanded: String?
    /// one muted line under the results, such as why plain search was used
    @Published public private(set) var note: String?
    let provider: SearchProviding
    let pasteboard: NSPasteboard
    var smart: SmartSearch?
    let debounce: TimeInterval
    var smartTask: Task<Void, Never>?
    var vault: VaultSearching?
    let vaultDebounce: TimeInterval
    var vaultTask: Task<Void, Never>?
    /// the vault results of this query; they stay at the end when the model's picks arrive
    var vaultItems: [SearchItem] = []
    /// opens a vault result on Return
    let open: (URL) -> Void
    /// saves a note in the vault on ⌘S or ⌘D; nil: no saving
    var writer: VaultWriting?
    var library = PackLibrary()
    var context = Context()
    /// items from outside the packs, such as coaching from shell history
    var extra: [SearchItem] = []

    public init(provider: SearchProviding = LocalSearch(), pasteboard: NSPasteboard = .general, smart: SmartSearch? = nil,
                debounce: TimeInterval = 0.6, vaultDebounce: TimeInterval = 0.2,
                open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.provider = provider; self.pasteboard = pasteboard; self.smart = smart; self.debounce = debounce
        self.vaultDebounce = vaultDebounce; self.open = open
    }

    /// A new router (config change); the next query uses it.
    public func setSmart(_ s: SmartSearch?) { smart = s }

    /// The vault search, or nil to turn it off (config change); the next query uses it.
    public func setVault(_ v: VaultSearching?) { vault = v }

    /// The vault writer, or nil to turn saving off (config change).
    public func setWriter(_ w: VaultWriting?) { writer = w }

    /// True when ⌘S and ⌘D can save to the vault.
    public var canSave: Bool { writer != nil }

    /// The keys that save, for the line under the results.
    public static let saveHint = "⌘S  Save the query in the vault     ⌘D  Save the clipboard"

    /// ⌘S saves the query as a note; ⌘D (`clipboard`) saves the text on the clipboard, with the query as its title.
    /// Only these keys save. The line under the results tells the user what happens. False: nothing to save.
    @discardableResult public func saveToVault(clipboard: Bool) -> Bool {
        guard let writer else { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let (text, title) = clipboard ? (pasteboard.string(forType: .string) ?? "", q) : (q, "")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note = clipboard ? "The clipboard has no text to save." : "Type the text to save."
            return false
        }
        note = "Saving in the vault…"
        let raw = query
        Task { [weak self] in
            let line: String
            do { line = "Saved in the vault: \u{201C}\(try await writer.save(text: text, title: title))\u{201D}." }
            catch { line = "Sanketa could not save in the vault. \(Self.reason(error))" }
            guard let self, self.query == raw else { return }
            self.note = line
        }
        return true
    }

    /// A short reason for a failed save.
    nonisolated static func reason(_ e: Error) -> String {
        switch "\(e)" {
        case let s where s.contains("timeout"): return "The vault server did not answer in time."
        case let s where s.contains("notRunning"): return "The vault server did not start. See [vault] in the config."
        default: return "The vault server gave an error."
        }
    }

    /// The shortest query that searches the vault.
    public static let vaultMinLength = 3

    public func setSource(library: PackLibrary? = nil, context: Context? = nil, extra: [SearchItem]? = nil) {
        if let library { self.library = library }
        if let context { self.context = context }
        if let extra { self.extra = extra }
        if !query.isEmpty { refresh() }
    }

    /// Context packs (live tmux keys, menu shortcuts) win over library packs with the same id.
    /// Entries in a layer's active pack context are marked `active`. `extra` items come last.
    var items: [SearchItem] {
        let ids = Set(context.packs.map(\.id))
        let active = Dictionary(context.layers.compactMap { l in l.context.flatMap { c in l.packID.map { ($0, c) } } }) { a, _ in a }
        let rest = library.packs.values.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id }
        return (context.packs + rest).flatMap { SearchItem.items(from: $0, context: active[$0.id]) } + extra
    }

    /// The tmux-style prefix of a result's pack, so its keys render in Mac symbols.
    public func prefix(for packID: String) -> String? {
        (context.packs.first { $0.id == packID } ?? library.packs[packID])?.prefix
    }

    func refresh() {
        smartTask?.cancel()
        smartTask = nil
        vaultTask?.cancel()
        vaultTask = nil
        vaultItems = []
        let ctx = context.layers.compactMap(\.packID)
        results = query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : Self.byPack(provider.results(query, items, context: ctx))
        selection = 0
        expanded = nil
        picked = []
        note = nil
        searchVault()
        guard let smart, query.split(whereSeparator: \.isWhitespace).count >= 3 else { return }
        let (q, all, wait) = (query, items, debounce)
        smartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let r = await smart.results(q, all, context: ctx)
            guard !Task.isCancelled, let self, self.query == q else { return }
            self.apply(r)
        }
    }

    /// After `vaultDebounce`, the vault results go at the end. The selected row stays selected.
    func searchVault() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let vault, q.count >= Self.vaultMinLength else { return }
        let (raw, wait) = (query, vaultDebounce)
        vaultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let r = await vault.search(q)
            guard !Task.isCancelled, let self, self.query == raw, !r.isEmpty else { return }
            let keep = self.selected?.id
            self.vaultItems = r
            self.results = self.results.filter { $0.kind != .vault } + r
            self.selection = keep.flatMap { id in self.results.firstIndex { $0.id == id } } ?? 0
        }
    }

    /// The model's picks first, then the rest by pack, then the vault. The selected row stays selected when it is still
    /// there.
    func apply(_ r: SmartResult) {
        let keep = selected?.id
        let picks = r.items.filter { r.picked.contains($0.id) }
        results = picks + Self.byPack(r.items.filter { !r.picked.contains($0.id) }) + vaultItems
        selection = selection == 0 ? 0 : keep.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        picked = r.picked
        note = r.note
    }

    /// Results of one pack together, under one heading; packs in the order of their best result.
    static func byPack(_ r: [SearchItem]) -> [SearchItem] {
        var order = [String](), groups = [String: [SearchItem]]()
        for i in r {
            if groups[i.packID] == nil { order.append(i.packID) }
            groups[i.packID, default: []].append(i)
        }
        return order.flatMap { groups[$0]! }
    }

    public var selected: SearchItem? { results.indices.contains(selection) ? results[selection] : nil }

    public func select(_ i: Int) { if results.indices.contains(i) { selection = i } }

    public func move(_ by: Int) { selection = max(0, min(results.count - 1, selection + by)) }

    /// A click on a result: it is selected and shows all its text, or goes back to one short line.
    public func click(_ i: Int) {
        guard results.indices.contains(i) else { return }
        selection = i
        expanded = expanded == results[i].id ? nil : results[i].id
    }

    /// Opens the selected vault result that has a target. Else copies the selected item's command or snippet; nil when
    /// nothing is selected or it has nothing to copy.
    @discardableResult public func activate() -> SearchItem? {
        guard let s = selected else { return nil }
        if let u = s.open { open(u); return s }
        guard let t = s.copyText else { return nil }
        pasteboard.clearContents()
        pasteboard.setString(t, forType: .string)
        return s
    }

    public func clear() { query = "" }
}
