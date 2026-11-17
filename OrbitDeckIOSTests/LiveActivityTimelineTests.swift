import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Live Activity pass timeline
//
// The widget picks what to show from the embedded pass list at draw time, and the
// app sets the stale date from `passChange(after:)`, so these rules decide what the
// Lock Screen and Dynamic Island show while OrbitDeck isn't running.

struct LiveActivityTimelineTests {
    typealias Pass = OrbitDeckPassAttributes.Pass
    typealias State = OrbitDeckPassAttributes.ContentState

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    func pass(_ name: String, aos: Double, los: Double, switchAt: Double? = nil) -> Pass {
        Pass(satellite: name, aos: at(aos), los: at(los), maxElevation: 40, switchAt: switchAt.map(at))
    }

    func state(_ source: OrbitDeckPassAttributes.Source, _ passes: [Pass]) -> State {
        let first = passes[0]
        return State(satellite: first.satellite, aos: first.aos, los: first.los, maxElevation: first.maxElevation,
                     switchAt: first.switchAt, source: source, inPass: false, utc: true, passes: passes)
    }

    @Test func showsNextThenInProgressThenNext() {
        let s = state(.favorite, [pass("A", aos: 10, los: 20), pass("B", aos: 60, los: 70)])
        #expect(s.pass(at: at(0))?.satellite == "A")
        #expect(s.pass(at: at(15))?.satellite == "A")
        #expect(s.pass(at: at(20))?.satellite == "B")    // at LOS it moves on
        #expect(s.pass(at: at(70)) == nil)
    }

    @Test func staleDateIsTheLOSNotTheAOS() {
        // The widget's timers cover AOS; the one redraw is spent where the pass changes.
        let s = state(.favorite, [pass("A", aos: 10, los: 20), pass("B", aos: 60, los: 70)])
        #expect(s.passChange(after: at(0)) == at(20))
        #expect(s.passChange(after: at(20)) == at(70))
        #expect(s.passChange(after: at(70)) == nil)
        // The app still recomputes at every transition while it runs.
        #expect(s.nextTransition(after: at(0)) == at(10))
    }

    @Test func favoritesKeepTheEarlierOverlappingPass() {
        let s = state(.favorite, [pass("A", aos: 10, los: 25), pass("B", aos: 20, los: 30)])
        #expect(s.pass(at: at(22))?.satellite == "A")
        #expect(s.pass(at: at(25))?.satellite == "B")
        #expect(s.passChange(after: at(12)) == at(25))
    }

    @Test func prioritiesFollowTheLatestSwitch() {
        // B preempts A at 18 (before B's AOS at 19: a negative take-over).
        let s = state(.priority, [pass("A", aos: 10, los: 25), pass("B", aos: 19, los: 30, switchAt: 18)])
        #expect(s.pass(at: at(17))?.satellite == "A")
        #expect(s.pass(at: at(18))?.satellite == "B")
        #expect(s.passChange(after: at(12)) == at(18))
    }

    @Test func followingIsTheNextInStartOrder() {
        let a = pass("A", aos: 10, los: 20), b = pass("B", aos: 60, los: 70)
        let s = state(.favorite, [b, a])    // unsorted input
        #expect(s.timeline.map(\.satellite) == ["A", "B"])
        #expect(s.following(a) == b)
        #expect(s.following(b) == nil)
    }

    @Test func legacyContentWithoutListDecodes() throws {
        // Content encoded by a build before the look-ahead list and azimuths.
        let legacy = State(satellite: "SO-50", aos: at(5), los: at(15), maxElevation: 31, switchAt: nil,
                           source: .favorite, inPass: false, utc: false)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "passes")
        let decoded = try JSONDecoder().decode(State.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.passes == nil)
        #expect(decoded.timeline.count == 1)
        #expect(decoded.pass(at: at(0))?.satellite == "SO-50")

        let oldPass = #"{"n":"AO-91","a":0,"l":600,"e":42.5}"#
        let p = try JSONDecoder().decode(Pass.self, from: Data(oldPass.utf8))
        #expect(p.aosAzimuth == nil && p.switchAt == nil)

        let oldAttributes = try JSONDecoder().decode(OrbitDeckPassAttributes.self, from: Data("{}".utf8))
        #expect(oldAttributes.startedAt == nil)
    }

    @Test func contentStaysWellUnderTheSizeLimit() throws {
        let long = String(repeating: "X", count: 40)
        let passes = (0..<LiveActivityController.embeddedPassCount).map {
            Pass(satellite: long, aos: at(Double($0) * 90), los: at(Double($0) * 90 + 15), maxElevation: 88.8,
                 switchAt: at(Double($0) * 90 - 1), aosAzimuth: 359, losAzimuth: 181, norad: 99999)
        }
        let data = try JSONEncoder().encode(state(.priority, passes))
        #expect(data.count < 1500)
    }

    @Test func stabilizedKeepsShownPassesThroughPlanningJitter() {
        let old = [Pass(satellite: "A", aos: at(10), los: at(20), maxElevation: 40, switchAt: at(9),
                        aosAzimuth: 10, losAzimuth: 170)]
        let jittered = [Pass(satellite: "A", aos: at(10).addingTimeInterval(2), los: at(20).addingTimeInterval(-3),
                             maxElevation: 40.2, switchAt: at(9).addingTimeInterval(30),
                             aosAzimuth: 11, losAzimuth: 170)]
        #expect(LiveActivityController.stabilized(jittered, previous: old) == old)
        // A real change (switch moved by minutes) goes through.
        var moved = jittered
        moved[0].switchAt = at(5)
        #expect(LiveActivityController.stabilized(moved, previous: old) == moved)
    }

    @Test func scheduledPassIsBeyondTheRunningActivitysReach() {
        let list = [pass("A", aos: 10, los: 20), pass("B", aos: 60, los: 70),
                    pass("C", aos: 150, los: 160), pass("D", aos: 240, los: 250)]
        let plan = LiveActivityController.makePlan(from: list, source: .favorite, utc: true, now: at(0))
        #expect(plan.current?.satellite == "A")
        // A now, B after the redraw at A's LOS; so C is scheduled.
        #expect(plan.scheduled?.timeline.first?.satellite == "C")
    }

    @Test func backgroundWakeIsTheNextAOSBeforeThePass() {
        // The stale date stays at the pass change (the one redraw moves the activity
        // on); the background refresh aims at AOS first, then at the stale date.
        let s = state(.favorite, [pass("A", aos: 10, los: 20), pass("B", aos: 60, los: 70)])
        let stale = s.passChange(after: at(0)) ?? s.los
        #expect(stale == at(20))
        #expect(LiveActivityController.backgroundWake(for: s, staleDate: stale, now: at(0)) == at(10))
        // During the pass: LOS.
        let inPassStale = s.passChange(after: at(12)) ?? s.los
        #expect(LiveActivityController.backgroundWake(for: s, staleDate: inPassStale, now: at(12)) == at(20))
        // A switch before AOS (the pass change) comes first.
        let p = state(.priority, [pass("A", aos: 10, los: 25), pass("B", aos: 19, los: 30, switchAt: 18)])
        let pStale = p.passChange(after: at(12)) ?? p.los
        #expect(LiveActivityController.backgroundWake(for: p, staleDate: pStale, now: at(12)) == at(18))
    }

    @Test func noradDecodesFromOldPayloadsAndRoundTrips() throws {
        let old = #"{"n":"AO-91","a":0,"l":600,"e":42.5,"aa":10,"la":170}"#
        let p = try JSONDecoder().decode(Pass.self, from: Data(old.utf8))
        #expect(p.norad == nil)
        var withID = pass("ISS", aos: 10, los: 20)
        withID.norad = 25544
        let json = String(decoding: try JSONEncoder().encode(withID), as: UTF8.self)
        #expect(json.contains(#""i":25544"#))
        #expect(try JSONDecoder().decode(Pass.self, from: Data(json.utf8)).norad == 25544)
        // An older plan's pass without the ID is replaced by the new one that has it.
        #expect(LiveActivityController.stabilized([withID], previous: [pass("ISS", aos: 10, los: 20)]) == [withID])
    }

    @Test func satelliteLinksParse() throws {
        let url = try #require(OrbitDeckPassAttributes.url(norad: 25544))
        #expect(url.absoluteString == "orbitdeck://satellite/25544")
        #expect(OrbitDeckPassAttributes.norad(from: url) == 25544)
        #expect(OrbitDeckPassAttributes.norad(from: URL(string: "ORBITDECK://Satellite/7530")!) == 7530)
        #expect(OrbitDeckPassAttributes.url(norad: nil) == nil)
        #expect(OrbitDeckPassAttributes.url(norad: 0) == nil)
        for junk in ["orbitdeck://satellite/", "orbitdeck://satellite/abc", "orbitdeck://satellite/-5",
                     "orbitdeck://satellite/+5", "orbitdeck://satellite/0", "orbitdeck://satellite/25544/x",
                     "orbitdeck://satellite/25544?x=1", "orbitdeck://pass/25544", "https://satellite/25544",
                     "orbitdeck://satellite/99999999999999999999", "orbitdeck:satellite/25544"] {
            #expect(OrbitDeckPassAttributes.norad(from: URL(string: junk)!) == nil, "\(junk)")
        }
    }

    @Test func scheduledActivityStartsAfterTheReachablePassSets() {
        // A now, B after the redraw at A's LOS; C is scheduled. Its 15-minute lead
        // (C at 80 → 65) would start it during B (60-70): wait for B's LOS.
        let list = [pass("A", aos: 10, los: 20), pass("B", aos: 60, los: 70),
                    pass("C", aos: 80, los: 90), pass("D", aos: 240, los: 250)]
        let plan = LiveActivityController.makePlan(from: list, source: .favorite, utc: true, now: at(0))
        #expect(plan.scheduled?.timeline.first?.satellite == "C")
        #expect(plan.scheduledStart == at(70))
        // Far enough apart, the usual lead applies.
        let apart = [pass("A", aos: 10, los: 20), pass("B", aos: 60, los: 70), pass("C", aos: 150, los: 160)]
        #expect(LiveActivityController.makePlan(from: apart, source: .favorite, utc: true, now: at(0))
            .scheduledStart == at(135))
    }

    @Test func elementsFingerprintChangesWithAnEpoch() {
        let a = [t0, at(60)], b = [t0, at(120)]
        #expect(LiveActivityController.elementsFingerprint(a) == LiveActivityController.elementsFingerprint(a))
        #expect(LiveActivityController.elementsFingerprint(a) != LiveActivityController.elementsFingerprint(b))
    }

    @Test func candidatesFallBackToTheSelection() {
        #expect(LiveActivityController.candidateIDs(usePriorities: true, priorities: [3, 1], favorites: [2],
                                                    selected: 9) == [3, 1])
        #expect(LiveActivityController.candidateIDs(usePriorities: false, priorities: [3], favorites: [5, 2],
                                                    selected: 9) == [2, 5])
        #expect(LiveActivityController.candidateIDs(usePriorities: false, priorities: [], favorites: [],
                                                    selected: 9) == [9])
    }
}
