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
    public var pack: Pack
    public var groups: [RowGroup]
    public var id: String { layer.id }
}

/// What the panel shows for a `Context`: per-layer sections, one tip card, and footer notes.
@MainActor public final class PanelModel: ObservableObject {
    @Published public private(set) var context = Context()
    @Published public private(set) var sections: [LayerSectionData] = []
    @Published public private(set) var tip: SearchItem?
    @Published public var collapsed: Set<String> = []
    @Published public var packErrors: [PackLoadError] = []
    @Published public var hotkeyConflict: String?
    public private(set) var seed: UInt64
    let tips: TipStore

    public init(tips: TipStore, seed: UInt64 = .random(in: 0...UInt64.max)) {
        self.tips = tips; self.seed = seed
    }

    public var showsFooter: Bool { needsAccessibility || !packErrors.isEmpty || hotkeyConflict != nil }
    public var needsAccessibility: Bool { !context.axTrusted && !context.bundleID.isEmpty }

    /// Layers paired with their packs; `Context.packs` is the packs of `layers` in order, skipping layers without one.
    public static func sections(_ c: Context) -> [LayerSectionData] {
        var packs = c.packs[...]
        return c.layers.compactMap { l in
            guard let p = packs.first, p.id == l.packID else { return nil }
            packs = packs.dropFirst()
            guard !p.keys.isEmpty || !p.tips.isEmpty else { return nil }
            return LayerSectionData(layer: l, pack: p, groups: groups(p.keys))
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
        if reseed { seed &+= 1 }
        pickTip()
    }

    public func rotate() { seed &+= 1; pickTip() }

    public func mark(_ m: TipMark) {
        guard let t = tip else { return }
        tips.set(t.id, m)
        rotate()
    }

    public func toggle(_ id: String) { if collapsed.remove(id) == nil { collapsed.insert(id) } }

    /// Items the tip card draws from: the context packs' keys and tips.
    public var tipPool: [SearchItem] { sections.flatMap { SearchItem.items(from: $0.pack) } }

    func pickTip() { tip = tips.pick(from: tipPool, count: 1, seed: seed).first }
}
