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
    /// A group folds only when it has a heading to click and more than `PanelModel.alwaysOpen` keys.
    public var folds: Bool { name != nil && keys.count > PanelModel.alwaysOpen }
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

/// Fold marks and scroll offset of one layer stack, so a quick switch away and back finds the panel as it was.
struct StackState {
    var collapsed: Set<String>
    var folds: [String: Bool]
    var scroll: CGFloat
}

/// What the panel shows for a `Context`: per-layer sections, tip cards, layer selection and footer notes.
@MainActor public final class PanelModel: ObservableObject {
    @Published public private(set) var context = Context()
    @Published public private(set) var sections: [LayerSectionData] = []
    @Published public private(set) var tipCards: [SearchItem] = []
    /// sections that the user closed
    @Published public var collapsed: Set<String> = []
    /// groups that the user opened (false) or closed (true), by `groupID`; other groups take `defaultFolded`
    @Published public var folds: [String: Bool] = [:]
    @Published public private(set) var selectedLayer: String?
    /// keyboard focus is on the layer list rather than the search field
    @Published public var listFocused = false
    @Published public var translucency = Translucency.medium
    @Published public var packErrors: [PackLoadError] = []
    /// why config.toml did not load; Sanketa then uses the defaults
    @Published public var configError: PackLoadError?
    /// the footer lists every bad pack file, not only the count
    @Published public var showAllErrors = false
    @Published public var hotkeyConflict: String?
    /// The list top to bottom: the innermost layer's keys first, then the tip cards, then the outer layers.
    @Published public private(set) var blocks: [PanelBlock] = []
    /// Changes when the layer stack changes; the view then scrolls to `scrollTarget` and fades the list in.
    @Published public private(set) var scrollToken = 0
    /// where the list was when the user last left this stack; 0 (the top) for a new stack
    public private(set) var scrollTarget: CGFloat = 0
    /// the list's scroll offset, written by the view as the user scrolls; not published, so it costs no update
    public var scrollOffset: CGFloat = 0
    var memory: [(key: String, state: StackState)] = []
    public static let rememberedStacks = 8
    public private(set) var seed: UInt64
    let store: TipStore
    /// One tip card: tips stay below the keys.
    public static let tipCount = 1
    /// Groups with this many keys or fewer never fold: a fold line would save no space.
    public nonisolated static let alwaysOpen = 2

    public init(tips: TipStore, seed: UInt64 = .random(in: 0...UInt64.max)) {
        store = tips; self.seed = seed
    }

    public var showsFooter: Bool { needsAccessibility || !packErrors.isEmpty || configError != nil || hotkeyConflict != nil }
    public var needsAccessibility: Bool { !context.axTrusted && !context.bundleID.isEmpty }

    /// One footer line for a file that did not load. A click opens the file, or (for the count line) lists the files.
    public struct ErrorLine: Equatable {
        public enum Action: Equatable { case open(String), showAll }
        public var text: String
        public var action: Action
    }

    /// More bad pack files than this show as one count line until the user clicks it.
    public static let errorLinesShown = 2

    /// `duckdb.toml: key 2 has no action.`, one line per bad file, with the config file first.
    public var errorLines: [ErrorLine] {
        func line(_ e: PackLoadError) -> ErrorLine {
            let m = e.message.hasSuffix(".") ? e.message : e.message + "."
            return ErrorLine(text: "\((e.file as NSString).lastPathComponent): \(m)", action: .open(e.file))
        }
        let packs = packErrors.count > Self.errorLinesShown && !showAllErrors
            ? [ErrorLine(text: "\(packErrors.count) pack files did not load. Click to see them.", action: .showAll)]
            : packErrors.map(line)
        return (configError.map { [line($0)] } ?? []) + packs
    }

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

    /// Id of group `g` in section `s`, for `folds`.
    nonisolated static func groupID(_ s: LayerSectionData, _ g: RowGroup) -> String { s.id + "#" + g.id }

    /// The user's mark, else `defaultFolded`. A group that cannot fold (see `RowGroup.folds`) is always open.
    public func isFolded(_ s: LayerSectionData, _ g: RowGroup) -> Bool {
        guard g.folds else { return false }
        return folds[Self.groupID(s, g)] ?? defaultFolded(s, g)
    }

    /// The panel is an index: the first section opens its first 2 groups, the other sections their first group,
    /// and the rest show as one line each. With an active context, its groups are open and the others folded.
    public func defaultFolded(_ s: LayerSectionData, _ g: RowGroup) -> Bool {
        if s.layer.context != nil { return !g.inContext }
        let open = s.id == sections.first?.id ? 2 : 1
        return (s.groups.firstIndex(of: g) ?? 0) >= open
    }

    public func toggle(_ s: LayerSectionData, _ g: RowGroup) {
        guard g.folds else { return }
        folds[Self.groupID(s, g)] = !isFolded(s, g)
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

    /// Key of a layer stack for `memory`; a new pack context in the same stack keeps the key.
    nonisolated static func stackKey(_ layers: [Layer]) -> String { layers.map(\.id).joined(separator: " › ") }

    /// On a new layer stack: keep this stack's marks and scroll offset, and take back those of the new stack
    /// (the last `rememberedStacks` stacks). The tip card stays while its pack is in the stack; the timer changes it.
    public func update(_ c: Context) {
        let changed = c.layers != context.layers
        let old = Self.stackKey(context.layers), new = Self.stackKey(c.layers)
        context = c
        sections = Self.sections(c)
        if let s = selectedLayer, !sections.contains(where: { $0.id == s }) { selectedLayer = nil }
        if changed {
            if old != new { remember(old) }
            let st = old == new ? StackState(collapsed: collapsed, folds: folds, scroll: scrollOffset)
                : memory.first { $0.key == new }?.state ?? StackState(collapsed: [], folds: [:], scroll: 0)
            collapsed = st.collapsed; folds = st.folds; scrollTarget = st.scroll; scrollOffset = st.scroll
            if let s = sections.first, s.index == 0 { collapsed.remove(s.id) }   // the tool in front always opens
            scrollToken &+= 1
        }
        let packs = Set(sections.map(\.pack.id))
        if tipCards.isEmpty || tipCards.contains(where: { !packs.contains($0.packID) }) { seed &+= 1; pickTips() }
        blocks = Self.blocks(layers: c.layers, sections: sections, tips: !tipCards.isEmpty)
    }

    func remember(_ key: String) {
        guard !key.isEmpty else { return }
        memory.removeAll { $0.key == key }
        memory.insert((key, StackState(collapsed: collapsed, folds: folds, scroll: scrollOffset)), at: 0)
        if memory.count > Self.rememberedStacks { memory.removeLast(memory.count - Self.rememberedStacks) }
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

    /// Layer index of the section with keyboard focus, for the breadcrumb.
    public var focusedLayerIndex: Int? { selectedLayer.flatMap { id in sections.first { $0.id == id }?.index } }

    /// With one layer (an app such as Finder), the breadcrumb names it, so its section header does not.
    public var showsSectionNames: Bool { context.layers.count > 1 }

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
