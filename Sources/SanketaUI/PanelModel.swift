import Foundation
import Combine
import SanketaCore
import SanketaSystem

public struct RowGroup: Identifiable, Equatable {
    public var name: String?
    public var keys: [KeyEntry]
    /// false for a group outside the layer's active context; such a group starts folded
    public var inContext = true
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

/// One block of the panel's list, top to bottom.
public enum PanelBlock: Identifiable, Equatable {
    case section(LayerSectionData)
    case tips
    /// a program or shell layer with no pack: one line that says how to add one
    case noPack(Layer, index: Int)

    public var id: String {
        switch self {
        case .section(let s): s.id
        case .tips: "tips"
        case .noPack(let l, let i): "nopack|" + PanelModel.sectionID(i, l)
        }
    }
}

/// What the panel shows for a `Context`: per-layer sections, tip cards, layer selection and footer notes.
@MainActor public final class PanelModel: ObservableObject {
    @Published public private(set) var context = Context()
    @Published public private(set) var sections: [LayerSectionData] = []
    @Published public private(set) var tipCards: [SearchItem] = []
    @Published public var collapsed: Set<String> = []
    /// out-of-context groups that the user opened
    @Published public var expanded: Set<String> = []
    @Published public private(set) var selectedLayer: String?
    /// keyboard focus is on the layer list rather than the search field
    @Published public var listFocused = false
    @Published public var translucency = Translucency.medium
    @Published public var packErrors: [PackLoadError] = []
    @Published public var hotkeyConflict: String?
    /// The list top to bottom: the innermost layer's keys first, then the tip cards, then the outer layers.
    @Published public private(set) var blocks: [PanelBlock] = []
    /// Changes when the layer stack changes, so the view scrolls back to the top and the new tool's keys show.
    @Published public private(set) var scrollToken = 0
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
            return LayerSectionData(layer: l, index: i, pack: ordered(p, context: l.context), groups: groups(p, context: l.context))
        }
    }

    /// Keys grouped as `groups(_:)`; with an active context its groups come first and the others are out of context.
    public static func groups(_ p: Pack, context: String?) -> [RowGroup] {
        let all = groups(p.keys)
        guard let context else { return all }
        let inside = all.filter { g in g.keys.contains { p.key($0, isIn: context) } }
        return inside + all.filter { !inside.contains($0) }.map { var g = $0; g.inContext = false; return g }
    }

    /// The pack with the active context's keys and tips first, so tip cards and search take them first.
    public static func ordered(_ p: Pack, context: String?) -> Pack {
        guard let context else { return p }
        var o = p
        let k = p.keys.filter { p.key($0, isIn: context) }, t = p.tips.filter { p.tip($0, isIn: context) }
        o.keys = k + p.keys.filter { !k.contains($0) }
        o.tips = t + p.tips.filter { !t.contains($0) }
        return o
    }

    /// Id of group `g` in section `s`, for `collapsed` and `expanded`.
    nonisolated static func groupID(_ s: LayerSectionData, _ g: RowGroup) -> String { s.id + "#" + g.id }

    /// A group is folded when it is out of context and not opened, or in context and closed.
    public func isFolded(_ s: LayerSectionData, _ g: RowGroup) -> Bool {
        let id = Self.groupID(s, g)
        return g.inContext ? collapsed.contains(id) : !expanded.contains(id)
    }

    public func toggle(_ s: LayerSectionData, _ g: RowGroup) {
        let id = Self.groupID(s, g)
        if g.inContext { toggle(id) } else if expanded.remove(id) == nil { expanded.insert(id) }
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
        if reseed {
            seed &+= 1
            scrollToken &+= 1
            if let s = sections.first, s.index == 0 { collapsed.remove(s.id) }   // the new tool's keys open
        }
        pickTips()
        blocks = Self.blocks(layers: c.layers, sections: sections, tips: !tipCards.isEmpty)
    }

    /// Tool bindings beat tips: when the innermost layer has keys (or is a program with no pack), it leads and
    /// the tip cards follow it; otherwise the tip cards lead.
    public static func blocks(layers: [Layer], sections: [LayerSectionData], tips: Bool) -> [PanelBlock] {
        var out = [PanelBlock]()
        for (i, l) in layers.enumerated() {
            if let s = sections.first(where: { $0.index == i }) { out.append(.section(s)) }
            else if l.kind == .program || l.kind == .shell { out.append(.noPack(l, index: i)) }
        }
        guard tips else { return out }
        let leads: Bool = switch out.first {
        case .section(let s): s.index == 0 && !s.pack.keys.isEmpty
        case .noPack(_, let i): i == 0
        default: false
        }
        out.insert(.tips, at: leads ? 1 : 0)
        return out
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
    public var tipPool: [SearchItem] { sections.flatMap { SearchItem.items(from: $0.pack, context: $0.layer.context) } }

    /// First card from the innermost layer that has any (from its active context when that has any), the rest from
    /// all current layers.
    func pickTips() {
        let all = sections.lazy.map { SearchItem.items(from: $0.pack, context: $0.layer.context) }.first { !$0.isEmpty } ?? []
        let inner = all.contains(where: \.active) ? all.filter(\.active) : all
        let first = store.pick(from: inner, count: 1, seed: seed)
        let rest = store.pick(from: tipPool.filter { !first.contains($0) }, count: Self.tipCount - first.count, seed: seed &+ 0x9E37)
        tipCards = first + rest
    }
}
