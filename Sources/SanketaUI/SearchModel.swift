import AppKit
import Combine
import SanketaCore
import SanketaSystem

/// What a search shows: all results, only the keys and tips of the packs, or only the vault. ⌘E goes to the next one.
public enum SearchScope: Int, CaseIterable, Sendable {
    case all, shortcuts, vault

    /// the quiet label next to the search field
    public var label: String { ["All", "Shortcuts", "Vault"][rawValue] }
}

/// Query → ranked results over the library plus context packs, with a clamped selection. For 3 or more words, a model
/// may move its picks to the top after the user stops typing for `debounce` seconds. For 3 or more letters, vault results
/// join the ranking `vaultDebounce` seconds after the user stops typing. `Search.blend` ranks them all.
@MainActor public final class SearchModel: ObservableObject {
    @Published public var query = "" { didSet { if query != oldValue { refresh() } } }
    /// the results that search shows; a new scope searches again
    @Published public var scope = SearchScope.all { didSet { if scope != oldValue { refresh() } } }
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
    /// the pack results of this query, in the order of the provider or the model
    var packItems: [SearchItem] = []
    /// the vault results of this query, in vault rank
    var vaultItems: [SearchItem] = []
    /// opens a vault result on Return
    let open: (URL) -> Void
    /// saves a note in the vault on ⌘S or ⌘D; nil: no saving
    var writer: VaultWriting?
    /// resumes a ramabana session on ⌥Return; false when it could not
    public var resume: (String) -> Bool = { _ in false }
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

    /// The vault results asked for in the Vault scope. The All scope asks for the default of the vault search.
    public static let vaultWide = 20

    /// ⌘E (1) or ⇧⌘E (-1): the next or the previous scope, All → Shortcuts → Vault → All.
    public func cycleScope(_ by: Int) {
        let n = SearchScope.allCases.count
        scope = SearchScope(rawValue: ((scope.rawValue + by) % n + n) % n) ?? .all
    }

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
        packItems = query.trimmingCharacters(in: .whitespaces).isEmpty || scope == .vault ? [] : provider.results(query, items, context: ctx)
        picked = []
        rank()
        selection = 0
        expanded = nil
        note = nil
        searchVault()
        guard let smart, scope != .vault, query.split(whereSeparator: \.isWhitespace).count >= 3 else { return }
        let (q, all, wait) = (query, items, debounce)
        smartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let r = await smart.results(q, all, context: ctx)
            guard !Task.isCancelled, let self, self.query == q else { return }
            self.apply(r)
        }
    }

    /// The results of the scope, in one ranking.
    func rank() { results = Search.blend(query, packItems, vault: scope == .shortcuts ? [] : vaultItems, picked: picked) }

    /// After `vaultDebounce`, the vault results join the ranking. The selected row stays selected.
    func searchVault() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let vault, scope != .shortcuts, q.count >= Self.vaultMinLength else { return }
        let (raw, wait, wide) = (query, vaultDebounce, scope == .vault ? Self.vaultWide : nil)
        vaultTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            let r = if let wide { await vault.search(q, limit: wide) } else { await vault.search(q) }
            guard !Task.isCancelled, let self, self.query == raw, !r.isEmpty else { return }
            let keep = self.selected?.id
            self.vaultItems = r
            self.rank()
            self.selection = keep.flatMap { id in self.results.firstIndex { $0.id == id } } ?? 0
        }
    }

    /// The model's picks and the plain results, ranked with the vault results. The selected row stays selected when it
    /// is still there.
    func apply(_ r: SmartResult) {
        let keep = selected?.id
        packItems = r.items
        picked = r.picked
        rank()
        selection = selection == 0 ? 0 : keep.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        note = r.note
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

    /// Opens the selected vault result that has a target. A vault result with no target shows all its text, or goes
    /// back to one line, and gives nil: search stays open. Else copies the selected item's command or snippet; nil when
    /// nothing is selected or it has nothing to copy.
    @discardableResult public func activate() -> SearchItem? {
        guard let s = selected else { return nil }
        if let u = s.open { open(u); return s }
        if s.kind == .vault { click(selection); return nil }
        guard let t = s.copyText else { return nil }
        pasteboard.clearContents()
        pasteboard.setString(t, forType: .string)
        return s
    }

    public enum AltResult: Equatable { case none, resumed, opened }

    /// ⌥Return: resumes the selected ramabana session, or opens the file of the selected memory entry.
    @discardableResult public func activateAlt() -> AltResult {
        switch selected?.alt {
        case .resume(let id)?: return resume(id) ? .resumed : .none
        case .file(let u)?: open(u); return .opened
        case nil: return .none
        }
    }

    /// The keys of a vault result, in Mac symbols, for its row: what Return and ⌥Return do.
    public nonisolated static func keyHint(_ i: SearchItem) -> String? {
        guard i.kind == .vault else { return nil }
        let ret = i.open == nil ? "↩ Show all" : "↩ Open"
        switch i.alt {
        case .resume?: return ret + "     ⌥↩ Resume session"
        case .file?: return ret + "     ⌥↩ Open file"
        case nil: return ret
        }
    }

    /// Ends the search: the next search starts in the All scope.
    public func clear() {
        query = ""
        scope = .all
    }
}
