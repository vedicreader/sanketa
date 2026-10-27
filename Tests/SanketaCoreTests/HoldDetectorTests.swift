import Foundation
import Testing
import TOMLDecoder
@testable import SanketaCore

@Suite struct HoldDetectorTests {
    final class Fake { var input: TimeInterval = 10; var pending: (() -> Void)?; var all: [() -> Void] = []; var shown: [Set<Modifier>] = []; var hides = 0; var delays: [TimeInterval] = [] }
    func make(_ f: Fake, _ s: HoldSetting = .all) -> HoldDetector {
        let d = HoldDetector(delay: 0.25, singleDelay: 0.6, setting: s, sinceInput: { f.input }, schedule: { t, b in f.pending = b; f.all.append(b); f.delays.append(t) })
        d.onShow = { f.shown.append($0) }; d.onHide = { f.hides += 1 }; return d
    }
    let hyper = Set(Modifier.allCases)
    @Test func showsAfterAQuietHold() { let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.pending?(); #expect(f.shown == [hyper]); d.flags([], at: 1); #expect(f.hides == 1) }
    @Test func aKeyOrClickDuringTheHoldCancels() { let f = Fake(), d = make(f); d.flags(hyper, at: 0); f.input = 0.1; f.pending?(); #expect(f.shown.isEmpty) }
    @Test func oneModifierNeverShows() { let f = Fake(), d = make(f); d.flags([.shift], at: 0); #expect(f.pending == nil) }
    @Test func capsOnlySkipsOtherCombos() { let f = Fake(), d = make(f, .caps); d.flags([.opt, .ctrl], at: 0); #expect(f.pending == nil); d.flags(hyper, at: 1); f.pending?(); #expect(f.shown == [hyper]) }
    @Test func offNeverShows() { let f = Fake(), d = make(f, .off); d.flags(hyper, at: 0); f.pending?(); #expect(f.shown.isEmpty) }
    @Test func letGoBeforeTheDelayShowsNothing() { let f = Fake(), d = make(f); d.flags(hyper, at: 0); d.flags([], at: 0.2); f.pending?(); #expect(f.shown.isEmpty) }
    @Test func configReadsHold() throws { #expect(try TOMLDecoder().decode(Config.self, from: Data("hold = \"caps\"".utf8)).hold == .caps); #expect(Config().hold == .any) }

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
        #expect(c.hold == .any); #expect(c.hotkey == "ctrl+opt+j")
    }

    @Test func configReadsHoldAny() throws { #expect(try TOMLDecoder().decode(Config.self, from: Data("hold = \"any\"".utf8)).hold == .any) }

    // single-key holds: ⌃, ⌥ or ⌘ alone, only with `.any`
    @Test func whichModsQualifyForEachSetting() {
        let sets: [Set<Modifier>] = [[.shift], [.opt], [.ctrl], [.cmd], [.opt, .shift], [.cmd, .opt], hyper]
        let want: [HoldSetting: [Bool]] = [.off: [false, false, false, false, false, false, false],
                                           .caps: [false, false, false, false, false, false, true],
                                           .all: [false, false, false, false, true, true, true],
                                           .any: [false, true, true, true, true, true, true]]
        for (s, w) in want {
            let got = sets.map { m in let f = Fake(), d = make(f, s); d.flags(m, at: 0); f.pending?(); return f.shown == [m] }
            #expect(got == w, "\(s)")
        }
    }
    @Test func aSingleHoldWaitsLongerThanACombo() {
        let f = Fake(), d = make(f, .any); d.flags([.opt], at: 0); d.flags([.opt, .cmd], at: 1)
        #expect(f.delays == [0.6, 0.25])
        d.singleDelay = 1.5; d.flags([.cmd], at: 2); #expect(f.delays.last == 1.5)
    }
    @Test func aKeyDuringTheSingleWaitCancels() {
        let f = Fake(), d = make(f, .any); d.flags([.ctrl], at: 0); f.input = 0.4; f.pending?(); #expect(f.shown.isEmpty)
        d.flags([], at: 1); d.flags([.ctrl], at: 2); f.input = 0.6; f.pending?(); #expect(f.shown == [[.ctrl]])
    }
    @Test func aSingleHoldWithNothingToShowSkips() {
        let f = Fake(), d = make(f, .any); var asked = [Set<Modifier>]()
        d.hasKeys = { asked.append($0); return $0 != [.cmd] }
        d.flags([.cmd], at: 0); f.pending?(); #expect(f.shown.isEmpty); #expect(d.showing == nil)
        d.flags([.opt], at: 1); f.pending?(); #expect(f.shown == [[.opt]])
        d.flags([.cmd, .shift], at: 2); f.pending?(); #expect(f.shown == [[.opt], [.cmd, .shift]])
        #expect(asked == [[.cmd], [.opt]])   // combos always show, so they do not ask
    }
    @Test func releaseHidesASingleView() {
        let f = Fake(), d = make(f, .any); d.flags([.opt], at: 0); f.pending?(); #expect(d.showing == [.opt])
        d.flags([], at: 1); #expect(f.hides == 1); #expect(d.showing == nil)
    }
    @Test func combosOnlyWhileWaitingOnASingleStopsTheShow() {
        let f = Fake(), d = make(f, .any); d.flags([.opt], at: 0); d.setting = .all; f.pending?(); #expect(f.shown.isEmpty)
    }
}
