import Foundation

/// Which held combos show their keys: none, only Hyper (what Caps sends), or any combo of two or more modifiers.
public enum HoldSetting: String, Codable, CaseIterable, Sendable { case off, caps, all }

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
    private let sinceInput: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var mods: Set<Modifier> = []
    private var wait = 0

    public init(delay: TimeInterval = Config.dfltHoldDelay, setting: HoldSetting, sinceInput: @escaping () -> TimeInterval,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.delay = delay; self.setting = setting; self.sinceInput = sinceInput; self.schedule = schedule
    }

    /// The modifiers now held; call it on every change.
    public func flags(_ new: Set<Modifier>, at t: TimeInterval) {
        guard new != mods else { return }
        mods = new; wait += 1
        if showing != nil { showing = nil; onHide?() }
        guard qualifies(new) else { return }
        let id = wait
        schedule(delay) { [weak self] in
            guard let self, id == wait, qualifies(mods), sinceInput() >= delay else { return }
            showing = mods; onShow?(mods)
        }
    }

    private func qualifies(_ m: Set<Modifier>) -> Bool {
        switch setting {
        case .off: false
        case .caps: m == Set(Modifier.allCases)
        case .all: m.count >= 2
        }
    }
}
