import Testing
import AppKit
import SanketaSystem

@Suite struct AXReaderTests {
    @Test(.enabled(if: AXReader.isTrusted, "Accessibility not granted to the test runner; grant it to run for real"))
    func axReadsFinderMenus() throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let t0 = Date()
        let s = AXReader.menuShortcuts(pid: finder.processIdentifier)
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(s.contains { $0.keys == "⌘N" })
        #expect(s.contains { $0.keys == "⇧⌘N" })
        _ = AXReader.focusedWindowTitle(pid: finder.processIdentifier)
    }
}
