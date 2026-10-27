import Foundation

/// One line of the combo view; `chords` holds every binding the line stands for.
public struct ComboRow: Hashable, Sendable {
    public var keys: String
    public var action: String
    public var chords: [Chord]
    public var muted: Bool
    public var clash: Bool
    public var layer: String?
    /// the app key's command (for Leela, its action id); nil for AeroSpace rows
    public var command: String?
    /// the pack group of an app key, or the kind of an AeroSpace command; rows of one group are partners
    public var group: String?
    /// the pack id of an app row; nil for AeroSpace rows
    public var pack: String?
    /// one or two words for the AeroSpace bar; nil for app rows
    public var short: String?
    public init(keys: String, action: String, chords: [Chord], muted: Bool = false, clash: Bool = false, layer: String? = nil,
                command: String? = nil, group: String? = nil, pack: String? = nil, short: String? = nil) {
        self.keys = keys; self.action = action; self.chords = chords; self.muted = muted; self.clash = clash; self.layer = layer
        self.command = command; self.group = group; self.pack = pack; self.short = short
    }
}

/// The keys of one app layer (for example a Leela pane or a tmux table).
public struct AppKeys: Sendable {
    public var layer: String
    /// the pack id; the layer name when not given
    public var pack: String
    public var entries: [KeyEntry]
    public init(layer: String, pack: String? = nil, entries: [KeyEntry]) { self.layer = layer; self.pack = pack ?? layer; self.entries = entries }
}

public extension KeyEntry {
    /// The chords of `keys` ("Caps\u{a0}Z / ⌥⇧B"), in order.
    func chords(hyperLabel: String) -> [Chord] { keys.components(separatedBy: " / ").compactMap { Chord.sanketa($0, hyperLabel: hyperLabel) } }
}

/// What the panel shows while a modifier combo is held: AeroSpace keys, front-app keys, and the free keys.
public struct ComboView: Equatable, Sendable {
    public var mods: Set<Modifier>
    public var mode: String
    public var aero: [ComboRow]
    public var also: [String]
    public var appName: String
    public var app: [ComboRow]
    public var free: [String]

    static let keyboard = ["1234567890", "qwertyuiop", "asdfghjkl;'", "zxcvbnm,./"].flatMap { $0.map(String.init) }
    static let arrows = ["left", "up", "down", "right"], vim = ["h", "j", "k", "l"]

    /// The key without its modifiers; a pack range such as "1…⌥9" (from "⌥1…⌥9") shows as "1…9".
    static func keyLabel(_ key: String) -> String {
        let one = { (k: String) in String(KeyNotation.compose([Modifier.cmd.rawValue], k).dropFirst()) }
        let ends = key.components(separatedBy: "…").map { String($0.drop { Modifier(rawValue: String($0)) != nil }) }
        return ends.count == 2 && !ends.contains("") ? ends.map(one).joined(separator: "…") : one(key)
    }

    /// The modifiers of a combo in Mac order, or the hyper label for all four.
    public static func modsLabel(_ m: Set<Modifier>, _ hyperLabel: String) -> String {
        String(Chord(mods: m, key: "x").display(hyperLabel: hyperLabel).dropLast()).trimmingCharacters(in: .whitespaces)
    }

    public static func build(mods: Set<Modifier>, mode: String, aero: AeroSpaceConfig?, appName: String, apps: [AppKeys], hyperLabel: String) -> ComboView {
        let inMode = aero?.modes[mode] ?? [], main = mode == "main"
        let shown = main ? inMode.filter { $0.chord.mods == mods } : inMode
        var rows = aeroRows(shown, mods: mods, hyperLabel: hyperLabel)
        if main { rows = rows.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element) }

        let aeroChords = Set((inMode + (aero?.modes["main"] ?? [])).map(\.chord))
        var layers = [(String, [ComboRow])]()
        for a in apps {
            let rs: [ComboRow] = a.entries.compactMap { e in
                let cs = e.chords(hyperLabel: hyperLabel).filter { $0.mods == mods }
                return cs.isEmpty ? nil : ComboRow(keys: cs.map { keyLabel($0.key) }.joined(separator: " / "), action: e.action, chords: cs,
                                                   clash: cs.contains { aeroChords.contains($0) }, command: e.command, group: e.group, pack: a.pack)
            }
            if !rs.isEmpty { layers.append((a.layer, rs)) }
        }
        let appRows = layers.flatMap { l, rs in rs.map { var r = $0; r.layer = layers.count > 1 ? l : nil; return r } }
        let taken = Set(shown.filter { $0.chord.mods == mods }.map(\.chord.key) + appRows.flatMap(\.chords).map(\.key))
        return ComboView(mods: mods, mode: mode, aero: rows.map(\.1), also: main && aero != nil ? also(rows.map(\.1), aero!, mods, hyperLabel) : [], appName: appName,
                         app: appRows.filter { !$0.clash } + appRows.filter(\.clash), free: keyboard.filter { !taken.contains($0) }.map { $0.uppercased() })
    }

    /// Rows for bindings in file order; four arrows, H J K L and 1 to 9 of one command shape become one row.
    static func aeroRows(_ bs: [AeroBinding], mods: Set<Modifier>, hyperLabel: String) -> [(AeroKind, ComboRow, AeroBinding)] {
        var used = Set<Int>(), out = [(AeroKind, ComboRow, AeroBinding)]()
        func shape(_ b: AeroBinding) -> [String] {
            b.commands.map { c in var w = c.split(separator: " ").map(String.init); if w.last == b.chord.key { w[w.count - 1] = "#" }; return w.joined(separator: " ") }
        }
        func group(_ i: Int, _ keys: [String], same: (AeroBinding) -> Bool) -> [Int]? {
            let b = bs[i]
            let found = keys.compactMap { k in bs.indices.first { !used.contains($0) && bs[$0].kind == b.kind && bs[$0].chord.mods == b.chord.mods && bs[$0].chord.key == k && same(bs[$0]) } }
            return found.count == keys.count ? found : nil
        }
        for (i, b) in bs.enumerated() where !used.contains(i) {
            var members: [Int]?, keys = "", action = b.action
            if b.kind == .moveTile || b.kind == .focus, let set = [arrows, vim].first(where: { $0.contains(b.chord.key) }) {
                members = group(i, set) { $0.target != nil }
                keys = set.map(keyLabel).joined(separator: " ")
                if members != nil, let t = b.target { action = b.action.replacingOccurrences(of: " " + t, with: "") }
            } else if b.kind == .workspace || b.kind == .sendToWorkspace, Int(b.chord.key).map({ (1...9).contains($0) }) == true {
                members = group(i, (1...9).map(String.init)) { shape($0) == shape(b) }
                keys = "1 – 9"
                if members != nil { action = b.kind == .workspace ? "Go to a workspace" : "Send the tile to a workspace" + (b.action.hasSuffix(" and follow") ? " and follow" : "") }
            }
            let ms = members ?? [i]
            used.formUnion(ms)
            let label = b.chord.mods == mods ? keyLabel(b.chord.key) : b.chord.display(hyperLabel: hyperLabel)
            out.append((b.kind, ComboRow(keys: members == nil ? label : (b.chord.mods == mods ? "" : modsLabel(b.chord.mods, hyperLabel) + " ") + keys, action: action, chords: ms.map { bs[$0].chord }, muted: b.kind == .resize,
                                         group: String(describing: b.kind), short: b.short), b))
        }
        return out
    }

    /// "Send to a workspace also: ..." lines for the other combos of `main` that have such keys.
    static func also(_ rows: [ComboRow], _ aero: AeroSpaceConfig, _ mods: Set<Modifier>, _ hyperLabel: String) -> [String] {
        let main = aero.modes["main"] ?? [], here = Set(rows.flatMap(\.chords))
        return [(AeroKind.sendToWorkspace, "Send to a workspace"), (.workspace, "Go to a workspace")].compactMap { kind, title in
            guard main.contains(where: { $0.kind == kind && here.contains($0.chord) }) else { return nil }
            let others = main.filter { $0.kind == kind && $0.chord.mods != mods }
            var order = [Set<Modifier>]()
            for b in others where !order.contains(b.chord.mods) { order.append(b.chord.mods) }
            let items = order.flatMap { m -> [String] in
                let label = modsLabel(m, hyperLabel)
                return aeroRows(others.filter { $0.chord.mods == m }, mods: m, hyperLabel: hyperLabel).map { _, r, b in
                    let how = kind == .sendToWorkspace ? (b.commands.contains { $0.contains("--focus-follows-window") } ? " (follow)" : " (stay)") : ""
                    return [label, r.keys].filter { !$0.isEmpty }.joined(separator: " ") + how
                }
            }
            return items.isEmpty ? nil : "\(title) also: " + items.joined(separator: ", ")
        }
    }
}

/// The AeroSpace keys of a combo view as one line for the bar under the menu bar: "key word" pairs, a mode name first.
public struct AeroBar: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var keys: String
        public var word: String
    }
    /// "resize mode ·" while an AeroSpace mode is on
    public var lead: String?
    public var items: [Item]

    public static let tail = "· AeroSpace"
    /// the bar wraps to a new line when it is wider than this part of the screen
    public static let maxShare = 0.8

    /// The AeroSpace rows of `view`, grouped as in the panel, with compact keys ("←↑↓→", "1–9"); nil when it has none.
    public init?(view: ComboView) {
        guard !view.aero.isEmpty else { return nil }
        lead = view.mode == "main" ? nil : "\(view.mode) mode ·"
        items = view.aero.map { Item(keys: $0.keys.replacingOccurrences(of: " ", with: ""), word: $0.short ?? $0.action) }
    }

    /// The items of each line, in order: a line takes items while their widths and gaps fit in `max`. An item wider than
    /// `max` takes a line of its own.
    public static func wrap(_ widths: [Double], gap: Double, max: Double) -> [[Int]] {
        var lines = [[Int]](), width = 0.0
        for (i, w) in widths.enumerated() {
            if let last = lines.last, !last.isEmpty, width + gap + w <= max { lines[lines.count - 1].append(i); width += gap + w }
            else { lines.append([i]); width = w }
        }
        return lines
    }
}
