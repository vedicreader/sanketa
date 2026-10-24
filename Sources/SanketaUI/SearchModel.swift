import AppKit
import Combine
import SanketaCore
import SanketaSystem

/// Query → ranked results over the library plus context packs, with a clamped selection.
@MainActor public final class SearchModel: ObservableObject {
    @Published public var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published public private(set) var results: [SearchItem] = []
    @Published public private(set) var selection = 0
    let provider: SearchProviding
    let pasteboard: NSPasteboard
    var library = PackLibrary()
    var context = Context()

    public init(provider: SearchProviding = LocalSearch(), pasteboard: NSPasteboard = .general) {
        self.provider = provider; self.pasteboard = pasteboard
    }

    public func setSource(library: PackLibrary? = nil, context: Context? = nil) {
        if let library { self.library = library }
        if let context { self.context = context }
        if !query.isEmpty { refresh() }
    }

    /// Context packs (live tmux keys, menu shortcuts) win over library packs with the same id.
    /// Entries in a layer's active pack context are marked `active`.
    var items: [SearchItem] {
        let ids = Set(context.packs.map(\.id))
        let active = Dictionary(context.layers.compactMap { l in l.context.flatMap { c in l.packID.map { ($0, c) } } }) { a, _ in a }
        let rest = library.packs.values.filter { !ids.contains($0.id) }.sorted { $0.id < $1.id }
        return (context.packs + rest).flatMap { SearchItem.items(from: $0, context: active[$0.id]) }
    }

    /// The tmux-style prefix of a result's pack, so its keys render in Mac symbols.
    public func prefix(for packID: String) -> String? {
        (context.packs.first { $0.id == packID } ?? library.packs[packID])?.prefix
    }

    func refresh() {
        results = query.trimmingCharacters(in: .whitespaces).isEmpty ? []
            : provider.results(query, items, context: context.layers.compactMap(\.packID))
        selection = 0
    }

    public var selected: SearchItem? { results.indices.contains(selection) ? results[selection] : nil }

    public func select(_ i: Int) { if results.indices.contains(i) { selection = i } }

    public func move(_ by: Int) { selection = max(0, min(results.count - 1, selection + by)) }

    /// Copies the selected item's `detail`; nil when nothing is selected.
    @discardableResult public func activate() -> SearchItem? {
        guard let s = selected else { return nil }
        pasteboard.clearContents()
        pasteboard.setString(s.detail, forType: .string)
        return s
    }

    public func clear() { query = "" }
}
