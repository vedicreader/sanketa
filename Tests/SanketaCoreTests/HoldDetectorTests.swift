import Foundation
import Testing
import TOMLDecoder
@testable import SanketaCore

@Suite struct HoldDetectorTests {
    final class Fake { var input: TimeInterval = 10; var pending: (() -> Void)?; var all: [() -> Void] = []; var shown: [Set<Modifier>] = []; var hides = 0 }
    func make(_ f: Fake, _ s: HoldSetting = .all) -> HoldDetector {
        let d = HoldDetector(setting: s, sinceInput: { f.input }, schedule: { _, b in f.pending = b; f.all.append(b) })
        d.onShow = { f.shown.append($0) }; d.onHide = { f.hides += 1 }; return d
    }
    let hyper = Set(Modifier.allCases)
    @Test func showsAfterAQuietHold() { let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.pending?(); #expect(f.shown == [hyper]); d.flags([], at: 1); #expect(f.hides == 1) }
    @Test func aKeyOrClickDuringTheHoldCancels() { let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.input = 0.1; f.pending?(); #expect(f.shown.isEmpty) }
    @Test func oneModifierNeverShows() { let f = Fake(), d = make(f); d.flags([.shift], at: 0); #expect(f.pending == nil) }
    @Test func capsOnlySkipsOtherCombos() { let f = Fake(), d = make(f, .caps); d.flags([.opt, .ctrl], at: 0); #expect(f.pending == nil); d.flags(hyper, at: 1); f.pending?(); #expect(f.shown == [hyper]) }
    @Test func offNeverShows() { let f = Fake(), d = make(f, .off); d.flags(hyper, at: 0); f.pending?(); #expect(f.shown.isEmpty) }
    @Test func letGoBeforeTheDelayShowsNothing() { let f = Fake(), d = make(f); d.flags(hyper, at: 0); d.flags([], at: 0.2); f.pending?(); #expect(f.shown.isEmpty) }
    @Test func configReadsHold() throws { #expect(try TOMLDecoder().decode(Config.self, from: Data("hold = \"caps\"".utf8)).hold == .caps); #expect(Config().hold == .all) }

    @Test func aDifferentComboWhileShowingHidesThenWaits() {
        let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.pending?()
        d.flags([.cmd, .opt], at: 1); #expect(f.hides == 1); #expect(d.showing == nil)
        f.pending?(); #expect(f.shown == [hyper, [.cmd, .opt]]); #expect(d.showing == [.cmd, .opt])
    }
    @Test func aChangeWhileWaitingStartsANewWait() {
        let f = Fake(), d = make(f); d.flags([.cmd, .opt], at: 0); d.flags(hyper, at: 0.2)
        f.all[0](); #expect(f.shown.isEmpty)
        f.all[1](); #expect(f.shown == [hyper]); #expect(f.hides == 0)
    }
    @Test func aStaleBlockCannotShowAfterTheModsChanged() {
        let f = Fake(), d = make(f); d.flags(hyper, at: 0); d.flags([.cmd], at: 0.1); f.all[0](); #expect(f.shown.isEmpty)
        d.flags(hyper, at: 0.2); d.flags([.cmd, .opt], at: 0.3); d.flags(hyper, at: 0.4)
        f.all[1](); f.all[2](); #expect(f.shown.isEmpty)
        f.all[3](); #expect(f.shown == [hyper])
    }
    @Test func fewerThanTwoWhileShowingHides() {
        let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.pending?(); d.flags([.shift], at: 1)
        #expect(f.hides == 1); #expect(d.showing == nil); #expect(f.all.count == 1)
    }
    @Test func theSameModsAgainChangeNothing() {
        let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.pending?(); d.flags(hyper, at: 1)
        #expect(f.hides == 0); #expect(f.all.count == 1)
    }
    @Test func offWhileWaitingStopsTheShow() {
        let f = Fake(), d = make(f); d.flags(hyper, at: 0); d.setting = .off; f.pending?()
        #expect(f.shown.isEmpty)
    }
    @Test func capsWhileWaitingOnAnotherComboStopsTheShow() {
        let f = Fake(), d = make(f); d.flags([.cmd, .opt], at: 0); d.setting = .caps; f.pending?()
        #expect(f.shown.isEmpty)
    }
    @Test func offWhileShowingHidesAtOnce() {
        let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.pending?(); d.setting = .off
        #expect(f.hides == 1); #expect(d.showing == nil)
    }
    @Test func aBadHoldValueKeepsTheDefaultAndTheRest() throws {
        let c = try TOMLDecoder().decode(Config.self, from: Data("hold = \"al\"\nhotkey = \"ctrl+opt+j\"".utf8))
        #expect(c.hold == .all); #expect(c.hotkey == "ctrl+opt+j")
    }
}
