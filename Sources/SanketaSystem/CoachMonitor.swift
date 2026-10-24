import Foundation
import Combine
import SanketaCore

/// Coaching from local fish and bash history. Reads and analysis run off the main thread; a slow timer only `stat`s
/// the files, and the items change only when the history changed. Nothing it reads leaves this Mac.
@MainActor public final class CoachMonitor: ObservableObject {
    @Published public private(set) var items: [SearchItem] = []
    /// the history cache generation of the last published `items`
    public private(set) var generation: Int
    private var config: CoachConfig
    private let cache: HistoryCache
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "dev.sanketa.coach", qos: .utility)
    private var timer: Timer?
    private var entries: [HistoryEntry] = []
    /// set while off: the next read analyzes even when the files did not change
    private var stale = false

    public init(config: CoachConfig, cache: HistoryCache = HistoryCache(), interval: TimeInterval = 60) {
        self.config = config; self.cache = cache; self.interval = interval
        generation = cache.generation
    }

    /// Reads now, then on a repeating timer (tolerance 10 s at the 60 s default).
    public func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh {} } }
        t.tolerance = min(10, interval / 6)
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh {}
    }

    public func stop() { timer?.invalidate(); timer = nil }

    public func reload(config c: CoachConfig) {
        guard c != config else { return }
        config = c
        refresh {}
    }

    public func refreshNow() async { await withCheckedContinuation { k in refresh { k.resume() } } }

    /// Reads on `queue` and analyzes only when the cache generation moved; the result comes back through the main
    /// run loop, so it also lands while the main thread runs a nested run loop.
    private func refresh(_ done: @escaping @MainActor () -> Void) {
        let c = config
        guard c.enabled else {
            entries = []
            stale = true
            if !items.isEmpty { items = [] }
            return done()
        }
        let cache = cache, last = stale ? nil : generation
        queue.async {
            let es = cache.entries(fish: c.fishURL, bash: c.bashURL, maxEntries: c.maxEntries)
            let gen = cache.generation
            let new = gen == last ? nil : Coach.analyze(es).map(\.item)
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    if self.config == c {   // else the config changed while reading, and a newer read follows
                        self.entries = es
                        if let new { self.generation = gen; self.items = new; self.stale = false }
                    }
                    done()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// The last read's commands of `shell`, newest last.
    public func recent(shell: Shell, limit: Int) -> [HistoryEntry] {
        Array(entries.filter { $0.shell == shell }.suffix(max(0, limit)))
    }

    /// `--dump-coach` lines: shell, detector id and count. Only `full` adds the before and after text, for the user.
    public nonisolated static func dumpLines(_ cs: [Coaching], full: Bool) -> [String] {
        cs.map { c in [c.shell.rawValue, c.detectorID, String(c.count)] + (full ? [c.before, c.after] : []) }
            .map { $0.joined(separator: "\t") }
    }
}
