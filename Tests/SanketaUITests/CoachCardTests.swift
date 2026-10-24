import AppKit
import Testing
@testable import SanketaCore
@testable import SanketaSystem
@testable import SanketaUI

/// The coaching card takes turns in the one tip slot, only at a local shell prompt of the same shell.
@MainActor struct CoachCardTests {
    static func coaching(_ shell: Shell) -> SearchItem {
        Coaching(detectorID: "grep-count", title: "Count matches with grep -c", shell: shell, before: "cat a | grep x | wc -l",
                 after: "grep -c x a", explain: "grep -c counts matching lines itself.", count: 3, lastSeen: nil).item
    }

    /// Seed 1: `update` moves it to 2, an even seed, where the coaching card has its turn.
    func model(_ url: URL? = nil, seed: UInt64 = 1) throws -> PanelModel {
        PanelModel(tips: TipStore(url: try url ?? tempURL("tips.json")), seed: seed)
    }

    @Test func coachCardShowsAtLocalShellPrompt() throws {
        let m = try model(), item = Self.coaching(.fish)
        m.coachItems = [item]
        m.update(try context(["fish", "Terminal"]))
        #expect(m.seed % 2 == 0)
        #expect(m.tipCards == [item])
        // the shell's own keys still lead; the card follows them
        #expect(m.blocks.first.map { if case .section(let s) = $0 { s.pack.id == "fish" } else { false } } == true)
        // the next turn (odd seed) is the shell's own tip
        m.rotate()
        #expect(m.tipCards.count == 1 && m.tipCards[0].packID == "fish")
        m.rotate()
        #expect(m.tipCards == [item])
    }

    @Test func coachCardStaysWhileTheStackUpdates() throws {
        let m = try model(), item = Self.coaching(.fish)
        m.coachItems = [item]
        let c = try context(["fish", "Terminal"])
        m.update(c)
        let seed = m.seed
        m.update(c)
        #expect(m.tipCards == [item] && m.seed == seed)
        m.coachItems = [item, Self.coaching(.bash)]   // the card is still there: no new pick
        #expect(m.tipCards == [item] && m.seed == seed)
        m.coachItems = []                              // the card is gone: a new pick
        #expect(!m.tipCards.contains(item) && m.tipCards.first?.packID == "fish")
    }

    @Test func noCoachCardInsideProgramOrRemote() throws {
        let item = Self.coaching(.fish)
        for seed in 0..<8 as Range<UInt64> {
            let m = try model(seed: seed)
            m.coachItems = [item]
            m.update(try context(["htop", "fish", "Terminal"]))
            #expect(!m.tipCards.contains(item))

            let r = try model(seed: seed)
            r.coachItems = [item]
            var c = try context(["fish", "Terminal"])
            c.layers[0].host = "box"
            r.update(c)
            #expect(!r.tipCards.contains(item))
        }
    }

    @Test func coachCardMatchesShell() throws {
        for seed in 0..<8 as Range<UInt64> {
            let m = try model(seed: seed)
            m.coachItems = [Self.coaching(.bash)]
            m.update(try context(["fish", "Terminal"]))
            #expect(!m.tipCards.contains(Self.coaching(.bash)))
        }
    }

    @Test func knownCoachingStaysHidden() throws {
        let url = try tempURL("tips.json"), item = Self.coaching(.fish)
        let m = try model(url)
        m.coachItems = [item]
        m.update(try context(["fish", "Terminal"]))
        #expect(m.tipCards == [item])
        m.mark(item, .known)
        for _ in 0..<4 { m.rotate(); #expect(!m.tipCards.contains(item)) }

        let again = try model(url)
        again.coachItems = [item]
        again.update(try context(["fish", "Terminal"]))
        for _ in 0..<4 { #expect(!again.tipCards.contains(item)); again.rotate() }
    }

    @Test func coachItemsAreSearchable() throws {
        let s = SearchModel(pasteboard: NSPasteboard(name: .init("sanketa-test-\(UUID().uuidString)")))
        let item = Self.coaching(.fish)
        s.setSource(library: PackLibrary(packs: try packs()), extra: [item])
        s.query = "grep -c"
        #expect(s.results.contains(item))
        s.setSource(extra: [])
        #expect(!s.results.contains(item))
    }
}
