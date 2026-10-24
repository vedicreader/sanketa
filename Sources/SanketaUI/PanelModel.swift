import Foundation
import Combine
import SanketaCore
import SanketaSystem

public struct RowGroup: Identifiable, Equatable {
    public var name: String?
    public var keys: [KeyEntry]
    public var id: String { name ?? "" }
}

public struct LayerSectionData: Identifiable, Equatable {
    public var layer: Layer
    /// position in `Context.layers`; part of the id because nested layers can share `Layer.id`
    public var index: Int
    public var pack: Pack
    public var groups: [RowGroup]
    public var id: String { PanelModel.sectionID(index, layer) }
}

/// What the panel shows for a `Context`: per-layer sections, tip cards, layer selection and footer notes.
@MainActor public final class PanelModel: ObservableObject {
    @Published public private(set) var context = Context()
    @Published public private(set) var sections: [LayerSectionData] = []
    @Published public private(set) var tipCards: [SearchItem] = []
    @Published public var collapsed: Set<String> = []
    @Published public private(set) var selectedLayer: String?
    /// keyboard focus is on the layer list rather than the search field
    @Published public var listFocused = false
    @Published public var translucency = Translucency.medium
    @Published public var packErrors: [PackLoadError] = []
    @Published public var hotkeyConflict: String?
    public private(set) var seed: UInt64
    let store: TipStore
    public static let tipCount = 3

    public init(tips: TipStore, seed: UInt64 = .random(in: 0...UInt64.max)) {
        store = tips; self.seed = seed
    }

    public var showsFooter: Bool { needsAccessibility || !packErrors.isEmpty || hotkeyConflict != nil }
    public var needsAccessibility: Bool { !context.axTrusted && !context.bundleID.isEmpty }

    nonisolated static func sectionID(_ i: Int, _ l: Layer) -> String { "\(i)|\(l.id)" }

    /// Layers paired with their packs; `Context.packs` is the packs of `layers` in order, skipping layers without one.
    public static func sections(_ c: Context) -> [LayerSectionData] {
        var packs = c.packs[...]
        return c.layers.enumerated().compactMap { i, l in
            guard let p = packs.first, p.id == l.packID else { return nil }
            packs = packs.dropFirst()
            guard !p.keys.isEmpty || !p.tips.isEmpty else { return nil }
            return LayerSectionData(layer: l, index: i, pack: p, groups: groups(p.keys))
        }
    }

    /// Keys grouped by `group`, groups in order of first appearance.
    public static func groups(_ keys: [KeyEntry]) -> [RowGroup] {
        var out = [RowGroup]()
        for k in keys {
            if let i = out.firstIndex(where: { $0.name == k.group }) { out[i].keys.append(k) }
            else { out.append(RowGroup(name: k.group, keys: [k])) }
        }
        return out
    }

    public func update(_ c: Context) {
        let reseed = c.layers != context.layers
        context = c
        sections = Self.sections(c)
        if let s = selectedLayer, !sections.contains(where: { $0.id == s }) { selectedLayer = nil }
        if reseed { seed &+= 1 }
        pickTips()
    }

    public func rotate() { seed &+= 1; pickTips() }

    public func mark(_ item: SearchItem, _ m: TipMark) {
        store.set(item.id, m)
        rotate()
    }

    public func toggle(_ id: String) { if collapsed.remove(id) == nil { collapsed.insert(id) } }

    /// Section id for the breadcrumb layer at `index`, if that layer has a section.
    public func sectionID(forLayerAt index: Int) -> String? {
        sections.first { $0.index == index }?.id
    }

    public func selectLayer(at index: Int) { if let id = sectionID(forLayerAt: index) { selectedLayer = id } }

    /// Moves the selected section by `by`, wrapping; starts at the first (or last) when none is selected.
    public func cycleLayer(_ by: Int) {
        guard !sections.isEmpty else { return }
        let n = sections.count
        let cur = selectedLayer.flatMap { s in sections.firstIndex { $0.id == s } }
        let next = cur.map { (($0 + by) % n + n) % n } ?? (by >= 0 ? 0 : n - 1)
        selectedLayer = sections[next].id
    }

    /// Items the tip cards draw from: the context packs' keys and tips, innermost layer first.
    public var tipPool: [SearchItem] { sections.flatMap { SearchItem.items(from: $0.pack) } }

    /// First card from the innermost layer that has any, the rest from all current layers.
    func pickTips() {
        let inner = sections.lazy.map { SearchItem.items(from: $0.pack) }.first { !$0.isEmpty } ?? []
        let first = store.pick(from: inner, count: 1, seed: seed)
        let rest = store.pick(from: tipPool.filter { !first.contains($0) }, count: Self.tipCount - first.count, seed: seed &+ 0x9E37)
        tipCards = first + rest
    }
}
