import Foundation

/// Which held modifiers show their keys: none, only Hyper (what Caps sends), any combo of two or more modifiers, or also
/// ⌃, ⌥ or ⌘ alone (⇧ alone never shows).
public enum HoldSetting: String, Codable, CaseIterable, Sendable { case off, caps, all, any }

/// Tells when the user holds a modifier combo and presses nothing else. The app feeds it `flags` and supplies the clock.
/// `flags`, the scheduled block and writes to `setting` all run on the main thread; there is no lock.
public final class HoldDetector {
    public var setting: HoldSetting {
        didSet {
            guard !qualifies(mods) else { return }
            wait += 1
            if showing != nil { showing = nil; onHide?() }
        }
    }
    public var onShow: ((Set<Modifier>) -> Void)?
    public var onHide: (() -> Void)?
    public private(set) var showing: Set<Modifier>?
    /// How long the combo must stay held, with no key, click or scroll, before the keys show.
    public var delay: TimeInterval
    /// The same wait for one modifier alone; longer, so a fast ⌃C or ⌘V never shows.
    public var singleDelay: TimeInterval
    /// Whether one modifier alone has keys to show; a single hold with none shows nothing. Combos always show.
    public var hasKeys: (Set<Modifier>) -> Bool = { _ in true }
    private let sinceInput: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var mods: Set<Modifier> = []
    private var wait = 0

    public init(delay: TimeInterval = Config.dfltHoldDelay, singleDelay: TimeInterval = Config.dfltSingleDelay, setting: HoldSetting,
                sinceInput: @escaping () -> TimeInterval, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.delay = delay; self.singleDelay = singleDelay; self.setting = setting; self.sinceInput = sinceInput; self.schedule = schedule
    }

    /// The modifiers now held; call it on every change.
    public func flags(_ new: Set<Modifier>, at t: TimeInterval) {
        guard new != mods else { return }
        mods = new; wait += 1
        if showing != nil { showing = nil; onHide?() }
        guard qualifies(new) else { return }
        let id = wait, single = new.count == 1, pause = single ? singleDelay : delay
        schedule(pause) { [weak self] in
            guard let self, id == wait, qualifies(mods), sinceInput() >= pause, !single || hasKeys(mods) else { return }
            showing = mods; onShow?(mods)
        }
    }

    private func qualifies(_ m: Set<Modifier>) -> Bool {
        switch setting {
        case .off: false
        case .caps: m == Set(Modifier.allCases)
        case .all: m.count >= 2
        case .any: m.count >= 2 || (m.count == 1 && m != [.shift])
        }
    }
}
