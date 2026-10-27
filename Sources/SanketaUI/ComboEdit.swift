import AppKit
import SanketaCore

/// One key change in the pinned combo view: the chord to change, where it is written, and the free chords to offer.
public struct KeyEdit: Equatable {
    /// `sanketa`: Sanketa's own search hotkey in config.toml
    public enum Source: Equatable { case aerospace(mode: String), leela(action: String, live: String), sanketa }
    public var row: ComboRow
    public var source: Source
    public var chord: Chord
    public var suggestions: [Suggestion]
    /// the name of the action in the confirm text
    public var action: String
    /// the file that the change writes
    public var file: URL?
    /// the new chord that the user picked or pressed; the confirm step shows when it is set
    public var new: Chord?
    /// the chord field has the focus and reads the next key press
    public var recording = false
    /// a line under the suggestions, such as which apps Sanketa did not check
    public var note: String?
    /// why the last pressed chord was not taken
    public var warning: String?
    /// "<chord> is in use by <owner>." for the new chord, and true when the same file uses it: then Change is off
    public var inUse: String?
    public var blocked = false
}

/// One line of the list that shows before an edit: a chord of a group row, or which app's key changes.
public struct EditChoice: Equatable {
    public var title: String
    public var row: ComboRow
    public var source: KeyEdit.Source
    public var chord: Chord
    public var action: String
}

/// What the edit step needs from the app: the AeroSpace config, the front app's keys and the files.
public struct EditSources {
    public var aero: AeroSpaceConfig?
    public var apps: [AppKeys]
    public var aeroFile: URL?
    public var leelaFile: URL?
    /// the chords of every pack that Sanketa knows; read only when an AeroSpace key changes
    public var known: () -> Set<Chord>
    /// Sanketa's config.toml; nil: Sanketa's own keys do not change
    public var sanketaFile: URL?
    /// the chords that macOS uses; read only when Sanketa's own key changes
    public var system: () -> Set<Chord>
    public init(aero: AeroSpaceConfig? = nil, apps: [AppKeys] = [], aeroFile: URL? = nil, leelaFile: URL? = nil, known: @escaping () -> Set<Chord> = { [] },
                sanketaFile: URL? = nil, system: @escaping () -> Set<Chord> = { KeySuggest.systemChords }) {
        self.aero = aero; self.apps = apps; self.aeroFile = aeroFile; self.leelaFile = leelaFile; self.known = known
        self.sanketaFile = sanketaFile; self.system = system
    }
}

/// A button in the toast, such as Undo.
public struct ToastAction {
    public let title: String
    public let run: () -> Void
    public init(title: String, run: @escaping () -> Void) { self.title = title; self.run = run }
}

extension PanelModel {
    public static let notChecked = "Sanketa does not check apps that have no pack."
    public static let reloadFailed = "Sanketa changed the file, but aerospace reload-config failed."
    /// the pack of Sanketa's own rows
    public static let sanketaPack = "sanketa"
    public static let searchAction = "Search"

    /// Sanketa's own keys for the combo view: Search, when the view is pinned or its chord uses the held modifiers.
    public func sanketaRows() -> [ComboRow] {
        guard let v = combo else { return [] }
        let c = Chord.hotkey(hotkey)
        guard comboPinned || c?.mods == v.mods else { return [] }
        return [ComboRow(keys: c?.display(hyperLabel: comboHyperLabel) ?? hotkey, action: Self.searchAction, chords: c.map { [$0] } ?? [],
                         command: "search", group: "Sanketa", pack: Self.sanketaPack)]
    }

    /// A click on the panel while the combo view shows: it stays after the let-go, until Esc or a click outside.
    public func pinCombo() { if combo != nil { comboPinned = true } }

    /// Ends the pin and any edit, and clears the combo view; true when the panel was shown only for the combo.
    @discardableResult public func unpinCombo() -> Bool {
        comboPinned = false
        cancelEdit()
        return hideCombo()
    }

    /// The chords of a row; a group row ("1 – 9") has one for each binding, and the user picks one.
    public static func editTargets(_ row: ComboRow) -> [Chord] { row.chords }

    public func canEdit(_ row: ComboRow, aero: Bool) -> Bool {
        guard let v = combo else { return false }
        return !Self.choices(row, aeroColumn: aero, view: v, sources: editSources, hyperLabel: comboHyperLabel).isEmpty
    }

    /// A click on a row pins the view. One chord starts the edit; a group row or a clash first lists the choices.
    public func clickRow(_ row: ComboRow, aero: Bool) {
        guard let v = combo else { return }
        pinCombo()
        let cs = Self.choices(row, aeroColumn: aero, view: v, sources: editSources, hyperLabel: comboHyperLabel)
        editing = nil
        if cs.count == 1, !row.clash { choose(cs[0]) } else { editChoices = cs }
    }

    public func choose(_ c: EditChoice) {
        editChoices = []
        guard let v = combo else { return }
        let i = Self.suggestInputs(row: c.row, chord: c.chord, source: c.source, view: v, sources: editSources, hyperLabel: comboHyperLabel)
        switch c.source {
        case .sanketa:
            let taken = hotkeyConflict.map { _ in "macOS or another app uses \(c.chord.display(hyperLabel: comboHyperLabel)) now." }
            editing = KeyEdit(row: c.row, source: c.source, chord: c.chord,
                              suggestions: KeySuggest.suggestHotkey(action: c.action, used: i.used, system: editSources.system(), hyperLabel: comboHyperLabel),
                              action: c.action, file: editSources.sanketaFile, note: taken)
        case .aerospace, .leela:
            let aero: Bool = if case .aerospace = c.source { true } else { false }
            editing = KeyEdit(row: c.row, source: c.source, chord: c.chord,
                              suggestions: KeySuggest.suggest(action: c.action, mods: c.chord.mods, partners: i.partners, used: i.used, hyperLabel: comboHyperLabel),
                              action: c.action, file: aero ? editSources.aeroFile : editSources.leelaFile, note: aero ? Self.notChecked : nil)
        }
    }

    /// The new chord: a suggestion or a pressed chord. The confirm step shows next. False: the chord is the key now, or
    /// it has no modifier outside an AeroSpace mode; the warning says why, and the field still reads.
    @discardableResult public func pick(_ c: Chord) -> Bool {
        guard let e = editing, let v = combo else { return false }
        let inMode: Bool = if case .aerospace(let m) = e.source, m != "main" { true } else { false }
        let leelaBad: Bool = if case .leela = e.source { c.leelaText == nil } else { false }
        let ownBad: Bool = if case .sanketa = e.source { !c.mods.isEmpty && c.hotkeyText == nil } else { false }
        let warning = leelaBad ? "Leela cannot use \(c.display(hyperLabel: comboHyperLabel)). Press a different chord."
            : ownBad ? "Sanketa cannot use \(c.display(hyperLabel: comboHyperLabel)) as a hotkey. Press a different chord."
            : c == e.chord ? "\(c.display(hyperLabel: comboHyperLabel)) is the key now. Press a different chord."
            : c.mods.isEmpty && !inMode ? "Press a chord with one or more modifier keys." : nil
        editing?.warning = warning
        guard warning == nil else { return false }
        let o = Self.owner(of: c, edit: e, view: v, sources: editSources, hyperLabel: comboHyperLabel)
        editing?.inUse = o.map { "\(c.display(hyperLabel: comboHyperLabel)) is in use" + ($0.name.map { " by \($0)" } ?? "") + "." }
        editing?.blocked = o?.blocks ?? false
        editing?.new = c
        editing?.recording = false
        return true
    }

    /// Who uses `c`: the same file first (AeroSpace in the edit's mode, or the edit's app), then AeroSpace, the front app's
    /// layers and, for an AeroSpace key, every pack. `blocks` is true for the same file, so a key is never written twice.
    public static func owner(of c: Chord, edit e: KeyEdit, view: ComboView, sources: EditSources, hyperLabel: String) -> (name: String?, blocks: Bool)? {
        func aeroIn(_ m: String) -> Bool { sources.aero?.modes[m]?.contains { $0.chord == c } == true }
        func app(_ ok: (AppKeys) -> Bool) -> AppKeys? { sources.apps.first { ok($0) && $0.entries.contains { $0.chords(hyperLabel: hyperLabel).contains(c) } } }
        switch e.source {
        case .aerospace(let mode):
            if aeroIn(mode) { return ("AeroSpace", true) }
            if aeroIn("main") { return ("AeroSpace", false) }
        case .leela:
            if let a = app({ $0.pack == e.row.pack }) { return (a.layer, true) }
            if aeroIn(view.mode) || aeroIn("main") { return ("AeroSpace", false) }
        case .sanketa:
            if sources.system().contains(c) { return ("macOS", false) }
            if aeroIn(view.mode) || aeroIn("main") { return ("AeroSpace", false) }
        }
        if let a = app({ _ in true }) { return (a.layer, false) }
        if case .aerospace = e.source, sources.known().contains(c) { return (nil, false) }
        return nil
    }

    /// The pinned view may read the files again; not while an edit is open.
    public var pinnedRefreshable: Bool { comboPinned && combo != nil && editing == nil }

    public func cancelEdit() { editing = nil; editChoices = [] }

    /// "Change <action>: <old> → <new> in <file>?", when a new chord is picked.
    public var confirmText: String? {
        guard let e = editing, let n = e.new, let f = e.file else { return nil }
        return "Change \(e.action): \(e.chord.display(hyperLabel: comboHyperLabel)) → \(n.display(hyperLabel: comboHyperLabel)) in \(Self.fileLabel(f))?"
    }

    /// The path with ~ for the home folder.
    public nonisolated static func fileLabel(_ url: URL, home: String = NSHomeDirectory()) -> String {
        url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// What can change for a row. AeroSpace rows (with a config file) and Leela rows with an action id can change; other
    /// app rows are read-only. A clash row offers the app's key first, then AeroSpace's key.
    public static func choices(_ row: ComboRow, aeroColumn: Bool, view: ComboView, sources: EditSources, hyperLabel: String) -> [EditChoice] {
        func aeroChoice(_ c: Chord, title: String?) -> EditChoice? {
            guard sources.aeroFile != nil, let a = sources.aero else { return nil }
            let mode = a.modes[view.mode]?.contains { $0.chord == c } == true ? view.mode : "main"
            guard let b = a.modes[mode]?.first(where: { $0.chord == c }) else { return nil }
            let r = view.aero.first { $0.chords.contains(c) } ?? ComboRow(keys: c.display(hyperLabel: hyperLabel), action: b.action, chords: [c], group: String(describing: b.kind))
            return EditChoice(title: title ?? "\(c.display(hyperLabel: hyperLabel)) · \(b.action)", row: r, source: .aerospace(mode: mode), chord: c, action: b.action)
        }
        if aeroColumn { return editTargets(row).compactMap { aeroChoice($0, title: nil) } }
        if row.pack == sanketaPack {
            guard sources.sanketaFile != nil, let c = row.chords.first else { return [] }
            return [EditChoice(title: c.display(hyperLabel: hyperLabel), row: row, source: .sanketa, chord: c, action: row.action)]
        }
        let leela = row.pack == LeelaKeymap.packID ? row.command : nil
        func leelaChoice(_ c: Chord, title: String) -> EditChoice? {
            leela.map { EditChoice(title: title, row: row, source: .leela(action: $0, live: live(row, apps: sources.apps, hyperLabel: hyperLabel)), chord: c, action: row.action) }
        }
        guard row.clash else { return editTargets(row).compactMap { leelaChoice($0, title: $0.display(hyperLabel: hyperLabel)) } }
        let taken = Set(((sources.aero?.modes[view.mode] ?? []) + (sources.aero?.modes["main"] ?? [])).map(\.chord))
        let clashing = row.chords.filter(taken.contains), name = sources.apps.first { $0.pack == row.pack }?.layer ?? view.appName
        return clashing.flatMap { c -> [EditChoice] in
            let which = clashing.count > 1 ? " " + c.display(hyperLabel: hyperLabel) : ""
            return [leelaChoice(c, title: "Change \(name)'s key" + which), aeroChoice(c, title: "Change AeroSpace's key" + which)].compactMap { $0 }
        }
    }

    /// The Leela value of the row's action, alternatives in order and separated by spaces ("hyper+z alt+shift+b"): every
    /// chord of the action, not only the chords of this combo, so the other chords stay when the action is not yet in `keys`.
    public static func live(_ row: ComboRow, apps: [AppKeys], hyperLabel: String) -> String {
        let entry = apps.filter { $0.pack == row.pack }.lazy.flatMap(\.entries).first { $0.command != nil && $0.command == row.command }
        return (entry?.chords(hyperLabel: hyperLabel) ?? row.chords).compactMap(\.leelaText).joined(separator: " ")
    }

    /// `used`: AeroSpace's current mode and `main`, the rows of this view and every chord of the front app's layers (with
    /// every pack Sanketa knows for an AeroSpace key); the chord that changes is in it too, so it is never offered. `partners`: the other chords of the
    /// row and the rows of its column with the same group.
    public static func suggestInputs(row: ComboRow, chord: Chord, source: KeyEdit.Source, view: ComboView, sources: EditSources,
                                    hyperLabel: String = "Caps") -> (partners: [Chord], used: Set<Chord>) {
        var used = Set(((sources.aero?.modes[view.mode] ?? []) + (sources.aero?.modes["main"] ?? [])).map(\.chord))
        used.formUnion((view.aero + view.app).flatMap(\.chords))
        used.formUnion(sources.apps.flatMap(\.entries).flatMap { $0.chords(hyperLabel: hyperLabel) })
        let column: [ComboRow]
        switch source {
        case .aerospace: used.formUnion(sources.known()); column = view.aero
        case .leela: column = view.app.filter { $0.pack == row.pack }
        case .sanketa: used.formUnion(sources.system()); used.formUnion(row.chords); column = []
        }
        let others = row.group == nil ? [] : column.filter { $0 != row && $0.group == row.group }
        return ((row.chords + others.flatMap(\.chords)).filter { $0 != chord }, used)
    }

    /// The chord of a key press: its modifiers and its key on an ANSI keyboard; nil for a modifier key alone.
    public nonisolated static func chord(keyCode: Int, flags: NSEvent.ModifierFlags) -> Chord? {
        guard let key = keyNames[keyCode] else { return nil }
        let f = flags.intersection(.deviceIndependentFlagsMask)
        let mods = Set([(NSEvent.ModifierFlags.control, Modifier.ctrl), (.option, .opt), (.shift, .shift), (.command, .cmd)].filter { f.contains($0.0) }.map(\.1))
        return Chord(mods: mods, key: key)
    }

    nonisolated static let keyNames: [Int: String] = {
        var n = [Int: String]()
        for (k, codes) in [("asdfhgzxcv", 0), ("bqweryt", 11), ("123465", 18)] { for (i, c) in k.enumerated() { n[codes + i] = String(c) } }
        let rest: [Int: String] = [24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p",
                                   36: "enter", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
                                   48: "tab", 49: "space", 50: "`", 51: "backspace", 53: "esc", 115: "home", 116: "pageup", 117: "delete", 119: "end",
                                   121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
                                   122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        return n.merging(rest) { a, _ in a }
    }()
}
