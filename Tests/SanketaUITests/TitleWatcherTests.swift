import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import SanketaCore
@testable import SanketaSystem

/// Our own test helper (Sources/SanketaTitleHost): an AppKit window whose title the test sets through stdin.
final class TitleHost {
    let process = Process()
    let input = Pipe(), output = Pipe()
    let exited = DispatchSemaphore(value: 0)
    var pid: pid_t { process.processIdentifier }

    static var binary: URL {
        // SwiftPM builds it next to the test bundle
        Bundle(for: TitleHost.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SanketaTitleHost")
    }

    init(_ title: String) throws {
        process.executableURL = Self.binary
        process.arguments = [title]
        process.standardInput = input
        process.standardOutput = output
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        _ = output.fileHandleForReading.availableData   // "ready"
    }

    func send(_ line: String) { input.fileHandleForWriting.write(Data((line + "\n").utf8)) }

    /// end of input quits the helper; terminate is the fallback, for our own child only
    func close() {
        try? input.fileHandleForWriting.close()
        if exited.wait(timeout: .now() + 2) == .timedOut { process.terminate(); process.waitUntilExit() }
    }
}

/// Runs the main run loop for `s` seconds and keeps the main actor all that time, so no other test's main-thread
/// work runs in it. Only for a CPU measurement of the main thread; to wait, use `pause` or `waitFor`.
@MainActor func holdMain(_ s: TimeInterval) {
    let end = Date().addingTimeInterval(s)
    let t = Timer(fire: end, interval: 0, repeats: false) { _ in }
    RunLoop.main.add(t, forMode: .default)
    while Date() < end { RunLoop.main.run(mode: .default, before: end) }
    t.invalidate()
}

/// Waits `s` seconds. It suspends, so it holds no thread and the main actor stays free for other tests.
func pause(_ s: TimeInterval) async { try? await Task.sleep(for: .seconds(s)) }

/// Checks `ok` every 20 ms for up to `s` seconds, with `pause` between the checks.
@MainActor func waitFor(_ s: TimeInterval = 2, _ ok: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + .seconds(s)
    while !ok(), ContinuousClock.now < end { await pause(0.02) }
    return ok()
}

final class Calls { var titles: [String?] = [] }

@MainActor @Suite(.serialized, .focusTest) struct TitleWatcherTests {
    @Test(.enabled(if: AXIsProcessTrusted()))
    func watcherFollowsTitleAndFocusedWindow() async throws {
        let host = try TitleHost("A0")
        defer { host.close() }
        #expect(await waitFor { AXReader.focusedWindowTitle(pid: host.pid) == "A0" })
        let calls = Calls()
        var w: AXTitleWatcher? = AXTitleWatcher(pid: host.pid) { calls.titles.append($0) }
        #expect(w != nil)
        await pause(0.3)   // the watcher registers on its own thread

        host.send("title A1")
        #expect(await waitFor { calls.titles.contains("A1") })
        host.send("title A2")
        #expect(await waitFor { calls.titles.contains("A2") })

        // a new focused window: the watcher moves to it
        host.send("window B0")
        #expect(await waitFor { calls.titles.contains("B0") })
        host.send("title B1")
        #expect(await waitFor { calls.titles.contains("B1") })
        await pause(0.3)
        let n = calls.titles.count
        host.send("set 0 A9")   // the first window is no longer focused
        await pause(0.7)
        #expect(calls.titles.count == n)

        // focus back to the first window
        host.send("front 0")
        #expect(await waitFor { calls.titles.last == "A9" })

        w = nil
        _ = w
        await pause(0.2)
        let m = calls.titles.count
        host.send("set 0 A10")
        await pause(0.7)
        #expect(calls.titles.count == m)
    }

    /// A page that ticks its title (a clock, an unread count) must not make Sanketa recompute: same pack, same scope.
    @Test(.enabled(if: AXIsProcessTrusted()))
    func tickingTitleDoesNotRefresh() async throws {
        let pack = try PackLibrary.decode(Data("""
        id = "ide"
        name = "IDE"
        title_apps = ["org.example.browser"]
        titles = ['^ide']
        title_scope = ' · ([a-z]+)$'
        [[contexts]]
        name = "notebook"
        scopes = ["notebook"]
        """.utf8))
        let host = try TitleHost("ide — inbox 0 · notebook")
        defer { host.close() }
        #expect(await waitFor { AXReader.focusedWindowTitle(pid: host.pid) != nil })
        let m = ContextMonitor(config: Config(), library: PackLibrary(packs: ["ide": pack]))
        m.isTrusted = { true }
        var refreshes = 0, changes = 0
        m.onTitleRefresh = { refreshes += 1 }
        m.makeWatcher = { pid, f in AXTitleWatcher(pid: pid) { changes += 1; f($0) } }
        m.watchTitle(pid: host.pid, bundleID: "org.example.browser")
        #expect(m.titles is AXTitleWatcher)
        await pause(0.3)
        host.send("title ide — inbox 1 · notebook")
        #expect(await waitFor { refreshes == 1 })   // the first title sets the key

        // the title ticks every 20 ms; the pack and scope stay the same
        host.send("tick 20 ide — inbox # · notebook")
        await pause(0.5)
        let t0 = threadCPUSeconds()
        holdMain(2)
        #expect(refreshes == 1)
        #expect(changes > 30)                     // the title did tick, and the watcher saw it
        #expect(threadCPUSeconds() - t0 < 0.1)   // ~100 title changes cost the main thread under 5 %

        host.send("tick 100000 ide — inbox · terminal")   // stops the fast tick
        host.send("title ide — inbox · terminal")
        #expect(await waitFor { refreshes == 2 })
    }
}

/// ContextMonitor with a fake watcher: debounce, key changes, app switches.
@MainActor struct ContextMonitorTitleTests {
    final class Fake { let pid: pid_t; let fire: (String?) -> Void; init(_ p: pid_t, _ f: @escaping (String?) -> Void) { pid = p; fire = f } }

    func monitor() throws -> (ContextMonitor, () -> [Fake], () -> Int) {
        let ide = try PackLibrary.decode(Data("""
        id = "ide"
        name = "IDE"
        apps = ["org.example.ide"]
        title_scope = ' · ([a-z]+)$'
        """.utf8))
        let leela = try PackLibrary.decode(Data("id = \"leela\"\nname = \"Leela\"\ntitles = ['^leela( |$)']\n".utf8))
        let m = ContextMonitor(config: Config(), library: PackLibrary(packs: ["ide": ide, "leela": leela]))
        var made: [Fake] = [], refreshes = 0
        m.makeWatcher = { pid, f in let w = Fake(pid, f); made.append(w); return w }
        m.isTrusted = { true }
        m.onTitleRefresh = { refreshes += 1 }
        m.titleDebounce = 0.05
        return (m, { made }, { refreshes })
    }

    @Test func refreshesOncePerChangeOfPackOrScope() async throws {
        let (m, made, refreshes) = try monitor()
        m.watchTitle(pid: 11, bundleID: "org.example.ide")
        let w = try #require(made().first)
        #expect(w.pid == 11 && m.titles === w)
        // a burst is debounced to one refresh
        w.fire("a · notebook"); w.fire("b · notebook"); w.fire("b · terminal")
        await pause(0.25)
        #expect(refreshes() == 1)
        w.fire("c · terminal"); w.fire("d · terminal")   // same scope: nothing to do
        await pause(0.25)
        #expect(refreshes() == 1)
        w.fire("d · notebook")
        await pause(0.25)
        #expect(refreshes() == 2)
    }

    @Test func appSwitchReplacesWatcher() async throws {
        let (m, made, refreshes) = try monitor()
        m.watchTitle(pid: 11, bundleID: "org.example.ide")
        m.watchTitle(pid: 22, bundleID: "com.google.Chrome")   // a browser that may host Leela
        #expect(made().count == 2 && m.titles === made()[1] && m.watched?.pid == 22)
        let chrome = made()[1]
        chrome.fire("Inbox (3) - Google Chrome"); await pause(0.15)
        chrome.fire("Inbox (4) - Google Chrome"); await pause(0.15)
        #expect(refreshes() == 1)                              // no pack either time: one refresh, for the first title
        chrome.fire("leela — x"); await pause(0.15)
        #expect(refreshes() == 2)

        m.watchTitle(pid: 33, bundleID: "com.apple.TextEdit")  // nothing reads its title
        #expect(m.titles == nil && made().count == 2)
        if let me = Bundle.main.bundleIdentifier {             // Sanketa itself in front keeps the watcher
            m.watchTitle(pid: 22, bundleID: "com.google.Chrome")
            m.watchTitle(pid: 44, bundleID: me)
            #expect(m.titles === made()[2])
        }
        m.isTrusted = { false }
        m.watchTitle(pid: 11, bundleID: "org.example.ide")
        #expect(m.titles == nil)
    }
}

/// An empty or timed-out menu read is read once more after a short delay, without another activation.
@MainActor @Suite(.serialized) struct ContextMonitorMenuRetryTests {
    /// Waits with the main queue free, so `refresh` can hand its result back on it.
    func idle(_ s: TimeInterval, until ok: () -> Bool = { false }) async throws {
        let end = Date().addingTimeInterval(s)
        while !ok(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    final class Reads: @unchecked Sendable {
        let lock = NSLock(); var count = 0
        var n: Int { lock.withLock { count } }
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    func monitor(_ reads: Reads, emptyReads: Int) -> ContextMonitor {
        let m = ContextMonitor(config: Config(), library: PackLibrary(packs: [:]))
        m.isTrusted = { false }   // no title watcher
        m.menuRetryDelay = 0.2
        m.computeContext = { pid, bid, name in
            let n = reads.next()
            let keys = n <= emptyReads ? [] : [MenuShortcut(path: ["File", "New Window"], keys: "⌘N")]
            var c = Context(appName: name, bundleID: bid, layers: [Layer(kind: .app, name: name, packID: "app:\(bid)")],
                            packs: [MenuKeys.pack(bundleID: bid, name: name, shortcuts: keys)], axTrusted: true)
            c.menuIncomplete = keys.isEmpty
            return c
        }
        return m
    }

    func finder() throws -> NSRunningApplication {
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    }

    @Test func emptyFirstReadIsReadAgain() async throws {
        let reads = Reads(), m = monitor(reads, emptyReads: 1)
        m.activated(try finder())
        try await idle(3) { m.context.packs.first?.keys.count == 1 }
        #expect(m.context.packs.first?.keys.count == 1)
        #expect(reads.n == 2)
    }

    @Test func readsAgainOnlyOncePerActivation() async throws {
        let reads = Reads(), m = monitor(reads, emptyReads: 99)
        m.activated(try finder())
        try await idle(3) { reads.n >= 2 }
        try await idle(1)           // the delay is 0.2 s: a second retry would come in this time
        #expect(reads.n == 2 && m.context.packs.first?.keys.isEmpty == true)
        m.activated(try finder())   // a new activation may try once more
        try await idle(3) { reads.n >= 4 }
        try await idle(1)
        #expect(reads.n == 4)
    }
}
