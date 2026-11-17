import Testing
import Foundation
@testable import OrbitDeck

// MARK: - PTT authority: ordering, cancellation and the safety limits
//
// `PTTAuthority` is the single path to the transmitter (FT4, Tune, packet, remote voice and
// the rigctld server all key through it). These tests drive it with a fake radio that
// records the frames it is asked to send, can hold a key or unkey "on the bus" until the
// test lets it go (a slow split/FT-847 pre-key, a busy transport), and collects the
// max-key-time timers instead of running them.

@MainActor
private final class FakeRadio {
    var frames: [String] = []
    /// Hold the next key/unkey until `finishKey()` / `finishUnkey()`.
    var slowKey = false
    var slowUnkey = false
    /// A key frame that goes out whatever `stillWanted` says (the release came too late).
    var keyIgnoresRelease = false
    var keyOutcome: PTTAuthority.KeyOutcome = .keyed
    var unkeySent = true
    /// Runs inside the key, right after the key frame (to interleave something before the
    /// owner's task resumes).
    var onKeySent: (@MainActor () -> Void)?
    private(set) var keyWaiting: CheckedContinuation<Void, Never>?
    private(set) var unkeyWaiting: CheckedContinuation<Void, Never>?
    var timers: [(seconds: TimeInterval, action: @MainActor @Sendable () -> Void)] = []

    /// The port holds the radio strongly (the radio never holds the authority), so a queued
    /// operation that runs after the test body returns still has its radio.
    func port() -> PTTAuthority.Port {
        PTTAuthority.Port(
            key: { stillWanted in
                if self.slowKey { await withCheckedContinuation { self.keyWaiting = $0 } }
                guard self.keyIgnoresRelease || stillWanted() else { return .notSent }
                self.frames.append("key")
                self.onKeySent?()
                return self.keyOutcome
            },
            unkey: {
                if self.slowUnkey { await withCheckedContinuation { self.unkeyWaiting = $0 } }
                self.frames.append("unkey")
                return self.unkeySent
            },
            sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) },
            schedule: { seconds, action in self.timers.append((seconds, action)) })
    }

    func finishKey() { keyWaiting?.resume(); keyWaiting = nil }
    func finishUnkey() { unkeyWaiting?.resume(); unkeyWaiting = nil }
}

/// Yield until `condition` holds (bounded, so a broken test fails instead of hanging).
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
}

@MainActor
struct PTTAuthorityTests {

    private func make() -> (FakeRadio, PTTAuthority) {
        let radio = FakeRadio()
        return (radio, PTTAuthority(port: radio.port()))
    }

    // MARK: Keying and releasing

    @Test func keyThenReleaseSendsKeyThenUnkey() async {
        let (radio, ptt) = make()
        let lease = await ptt.acquire(.ft4)
        #expect(lease?.owner == .ft4)
        #expect(ptt.isKeyed)
        let op = ptt.release(lease)
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
        #expect(radio.frames == ["key", "unkey"])
        #expect(!ptt.isKeyed && ptt.holder == nil && !ptt.mayBeKeyed)
    }

    @Test func secondOwnerIsRefusedWhileTheTransmitterIsHeld() async {
        let (radio, ptt) = make()
        let ft4 = await ptt.acquire(.ft4)
        #expect(ft4 != nil)
        #expect(await ptt.acquire(.network) == nil)
        #expect(await ptt.acquire(.ft4) == nil)
        #expect(radio.frames == ["key"])
        #expect(ptt.holder == .ft4)
    }

    // MARK: Stop during a slow key (FT4/packet H1/H3, voice H2)

    @Test func stopDuringSlowKeyEndsUnkeyedWithoutKeying() async {
        let (radio, ptt) = make()
        radio.slowKey = true
        let pending = Task { await ptt.acquire(.ft4) }
        await waitUntil { radio.keyWaiting != nil }
        // FT4 stop(): release whatever FT4 holds, the in-flight key included.
        let op = ptt.release(owners: [.ft4, .tune], unkeyIfIdle: true)
        radio.finishKey()
        #expect(await pending.value == nil)
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
        #expect(!radio.frames.contains("key"))
        #expect(radio.frames.last == "unkey")
        #expect(!ptt.isKeyed && ptt.holder == nil)
    }

    @Test func releaseAfterTheKeyFrameLeftIsFollowedByUnkey() async {
        let (radio, ptt) = make()
        radio.slowKey = true
        radio.keyIgnoresRelease = true      // the key frame was already on the bus
        let pending = Task { await ptt.acquire(.voice) }
        await waitUntil { radio.keyWaiting != nil }
        let op = ptt.release(owners: [.voice])
        radio.finishKey()
        #expect(await pending.value == nil)     // the owner never gets a lease it must release
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
        #expect(radio.frames == ["key", "unkey"])
        #expect(!ptt.isKeyed && !ptt.mayBeKeyed)
    }

    @Test func releaseCancelsAKeyThatHasNotStarted() async {
        let (radio, ptt) = make()
        // A slow unkey ahead in the queue keeps the key waiting its turn.
        radio.slowUnkey = true
        _ = ptt.release(owners: [], unkeyIfIdle: true)
        let pending = Task { await ptt.acquire(.packet) }
        await waitUntil { ptt.holder == .packet && radio.unkeyWaiting != nil }
        let op = ptt.release(owners: [.packet])
        radio.slowUnkey = false
        radio.finishUnkey()
        #expect(await pending.value == nil)
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
        #expect(radio.frames == ["unkey", "unkey"])
    }

    @Test func failedKeyFrameIsFollowedByUnkey() async {
        let (radio, ptt) = make()
        radio.keyOutcome = .failed          // the radio may have keyed
        #expect(await ptt.acquire(.ft4) == nil)
        await waitUntil { radio.frames.count == 2 }
        #expect(radio.frames == ["key", "unkey"])
        #expect(ptt.holder == nil && !ptt.mayBeKeyed)
    }

    // MARK: Stale generations

    @Test func staleLeaseCanNeitherKeyNorUnkeyTheCurrentGrant() async {
        let (radio, ptt) = make()
        let old = await ptt.acquire(.packet)
        let op = ptt.release(old)
        _ = await ptt.waitFor(op, timeoutMs: 1000)
        let current = await ptt.acquire(.packet)
        #expect(current != nil && current != old)
        // A watchdog from the earlier transmission fires late.
        #expect(ptt.release(old) == nil)
        #expect(ptt.holds(current) && ptt.isKeyed)
        #expect(radio.frames == ["key", "unkey", "key"])
    }

    @Test func otherOwnersStopLeavesTheHolderAlone() async {
        let (radio, ptt) = make()
        let network = await ptt.acquire(.network)
        // FT4 stops with nothing of its own on the air.
        #expect(ptt.release(owners: [.ft4, .tune], unkeyIfIdle: true) == nil)
        #expect(ptt.holds(network) && ptt.isKeyed)
        #expect(radio.frames == ["key"])
    }

    // MARK: Disconnect / link drop (H4)

    @Test func disconnectWhileKeyedSendsUnkeyBeforeClose() async {
        let (radio, ptt) = make()
        var forced: (PTTLease, String)?
        ptt.onForcedRelease = { forced = ($0, $1) }
        let lease = await ptt.acquire(.ft4)
        // RigController.disconnect(): unkey first, wait (bounded), then close the links.
        let mayBeKeyed = ptt.mayBeKeyed
        let op = ptt.releaseAll(reason: "CAT disconnected", forceUnkey: true)
        let sent = await ptt.waitFor(op, timeoutMs: 1500)
        radio.frames.append("close")
        #expect(sent && mayBeKeyed)
        #expect(radio.frames == ["key", "unkey", "close"])
        #expect(forced?.0 == lease && forced?.1 == "CAT disconnected")
        #expect(ptt.holder == nil)
    }

    @Test func disconnectSendsAnUnkeyEvenWhenNothingIsHeld() async {
        let (radio, ptt) = make()
        let op = ptt.releaseAll(reason: "CAT disconnected", forceUnkey: true)
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
        #expect(radio.frames == ["unkey"])
    }

    @Test func disconnectDuringSlowKeyNeverKeys() async {
        let (radio, ptt) = make()
        radio.slowKey = true
        let pending = Task { await ptt.acquire(.tune) }
        await waitUntil { radio.keyWaiting != nil }
        let op = ptt.releaseAll(reason: "CAT link dropped", forceUnkey: true)
        radio.finishKey()
        #expect(await ptt.waitFor(op, timeoutMs: 1500))
        radio.frames.append("close")
        #expect(await pending.value == nil)
        #expect(radio.frames == ["unkey", "close"])
    }

    @Test func unconfirmedUnkeyIsReportedWhenTheRadioMayBeKeyed() async {
        let (radio, ptt) = make()
        _ = await ptt.acquire(.voice)
        radio.unkeySent = false             // the link is already gone
        let mayBeKeyed = ptt.mayBeKeyed
        let op = ptt.releaseAll(reason: "CAT link dropped", forceUnkey: true)
        let sent = await ptt.waitFor(op, timeoutMs: 1000)
        #expect(!sent && mayBeKeyed)        // → RigController shows the PTT warning
        #expect(ptt.mayBeKeyed)             // no confirmed unkey since the key
    }

    @Test func boundedWaitGivesUpOnAStuckUnkey() async {
        let (radio, ptt) = make()
        radio.slowUnkey = true
        let op = ptt.releaseAll(reason: "CAT disconnected", forceUnkey: true)
        #expect(await ptt.waitFor(op, timeoutMs: 100) == false)
        radio.finishUnkey()
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
    }

    // MARK: Maximum key time

    @Test func maxKeyTimeBackstopUnkeysAndTellsTheOwner() async {
        let (radio, ptt) = make()
        var forced: (PTTLease, String)?
        ptt.onForcedRelease = { forced = ($0, $1) }
        let lease = await ptt.acquire(.voice, maxKeySeconds: 5)
        #expect(radio.timers.map(\.seconds) == [5])
        radio.timers[0].action()
        await waitUntil { radio.frames.count == 2 }
        #expect(radio.frames == ["key", "unkey"])
        #expect(ptt.holder == nil)
        #expect(forced?.0 == lease)
        #expect(forced?.1.contains("maximum key time") == true)
    }

    @Test func ownerLimitsAreCappedByTheGlobalMaximum() async {
        let (radio, ptt) = make()
        let first = await ptt.acquire(.network, maxKeySeconds: 10_000)
        ptt.release(first)
        _ = await ptt.acquire(.ft4)
        #expect(radio.timers.map(\.seconds) == [PTTAuthority.globalMaxKeySeconds, PTTOwner.ft4.maxKeySeconds])
        for owner in PTTOwner.allCases { #expect(owner.maxKeySeconds <= PTTAuthority.globalMaxKeySeconds) }
    }

    @Test func staleMaxKeyTimerDoesNothing() async {
        let (radio, ptt) = make()
        let old = await ptt.acquire(.packet, maxKeySeconds: 5)
        ptt.release(old)
        let current = await ptt.acquire(.packet, maxKeySeconds: 5)
        radio.timers[0].action()            // the first transmission's timer fires late
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(ptt.holds(current) && ptt.isKeyed)
        #expect(radio.frames == ["key", "unkey", "key"])
    }

    @Test func forcedReleaseBeforeTheOwnerResumesIsARefusal() async {
        let (radio, ptt) = make()
        var forced: PTTLease?
        ptt.onForcedRelease = { lease, _ in forced = lease }
        // A Stop all / disconnect lands after the key frame but before the owner's task
        // resumes with the lease: the owner must see a refusal, not store a dead lease.
        radio.onKeySent = { Task { @MainActor in ptt.releaseAll(reason: "Stop all") } }
        let lease = await ptt.acquire(.voice)
        #expect(lease == nil)
        #expect(forced?.owner == .voice)
        await waitUntil { radio.frames.count == 2 }
        #expect(radio.frames == ["key", "unkey"])
        #expect(ptt.holder == nil)
    }

    @Test func confirmedRejectsAReleasedLease() async {
        let (_, ptt) = make()
        let lease = await ptt.acquire(.packet)
        #expect(ptt.confirmed(lease) == lease)
        ptt.releaseAll(reason: "CAT disconnected")
        #expect(ptt.confirmed(lease) == nil)
        #expect(ptt.confirmed(nil) == nil)
    }

    // MARK: Unconfirmed unkey: reconnect and backstop retries

    @Test func reconnectSendsThePTTOffWhenTheUnkeyWasUnconfirmed() async {
        let (radio, ptt) = make()
        _ = await ptt.acquire(.ft4)
        radio.unkeySent = false             // the BLE link is already down
        let started = ptt.beginShutdownUnkey(reason: "CAT link dropped")
        #expect(await ptt.finishShutdownUnkey(started, timeoutMs: 1000) == false)
        #expect(ptt.unkeyUnconfirmed && ptt.keyFrameOut)
        // Auto-reconnect succeeds: the PTT-off goes out before the Doppler loop starts.
        radio.unkeySent = true
        #expect(await ptt.confirmUnkeyAfterReconnect(timeoutMs: 1000))
        #expect(radio.frames == ["key", "unkey", "unkey"])
        #expect(!ptt.unkeyUnconfirmed && !ptt.keyFrameOut)
    }

    @Test func failedReconnectUnkeyKeepsTheFlag() async {
        let (radio, ptt) = make()
        _ = await ptt.acquire(.voice)
        radio.unkeySent = false
        _ = await ptt.finishShutdownUnkey(ptt.beginShutdownUnkey(reason: "CAT link dropped"), timeoutMs: 1000)
        #expect(await ptt.confirmUnkeyAfterReconnect(timeoutMs: 1000) == false)
        #expect(ptt.unkeyUnconfirmed)
    }

    @Test func cleanReconnectSendsNothing() async {
        let (radio, ptt) = make()
        let lease = await ptt.acquire(.ft4)
        let started = ptt.beginShutdownUnkey(reason: "CAT disconnected")
        #expect(await ptt.finishShutdownUnkey(started, timeoutMs: 1000))
        ptt.noteTeardown()
        #expect(!ptt.unkeyUnconfirmed)
        #expect(await ptt.confirmUnkeyAfterReconnect(timeoutMs: 1000))
        #expect(radio.frames == ["key", "unkey"])
        #expect(ptt.confirmed(lease) == nil)
    }

    @Test func teardownWithAnUnansweredKeyFrameMarksTheUnkeyUnconfirmed() async {
        let (radio, ptt) = make()
        radio.unkeySent = false
        let lease = await ptt.acquire(.packet)
        let op = ptt.release(lease)
        _ = await ptt.waitFor(op, timeoutMs: 1000)
        #expect(ptt.keyFrameOut)
        ptt.noteTeardown()
        #expect(ptt.unkeyUnconfirmed)
    }

    @Test func backstopRetriesTheUnkeyWhileAKeyFrameIsUnanswered() async {
        let (radio, ptt) = make()
        let lease = await ptt.acquire(.voice, maxKeySeconds: 5)
        radio.unkeySent = false
        let op = ptt.release(lease)
        _ = await ptt.waitFor(op, timeoutMs: 1000)
        #expect(ptt.keyFrameOut && ptt.holder == nil)
        // The max-key timer fires with no grant left: it retries rather than giving up.
        radio.timers[0].action()
        await waitUntil { radio.frames.count == 3 }
        #expect(radio.frames == ["key", "unkey", "unkey"])
        #expect(radio.timers.count == 2 && radio.timers[1].seconds == PTTAuthority.unkeyRetrySeconds)
        // The link is back: the next retry gets through and the retries stop.
        radio.unkeySent = true
        radio.timers[1].action()
        await waitUntil { radio.frames.count == 4 }
        #expect(!ptt.keyFrameOut)
        let scheduled = radio.timers.count
        radio.timers[scheduled - 1].action()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(radio.frames.count == 4)
        #expect(radio.timers.count == scheduled)
    }

    // MARK: Background

    @Test func backgroundReleasesVoiceButKeepsFT4() async {
        let (radio, ptt) = make()
        let ft4 = await ptt.acquire(.ft4)
        #expect(ptt.releaseForBackground() == nil)
        #expect(ptt.holds(ft4))
        ptt.release(ft4)
        _ = await ptt.acquire(.voice)
        let op = ptt.releaseForBackground()
        #expect(op != nil)
        #expect(await ptt.waitFor(op, timeoutMs: 1000))
        #expect(ptt.holder == nil)
        #expect(radio.frames == ["key", "unkey", "key", "unkey"])
        #expect(!PTTOwner.voice.continuesInBackground && !PTTOwner.tune.continuesInBackground
                && !PTTOwner.network.continuesInBackground)
    }
}

// MARK: - Remote voice: a dead carrier is never keyed

@MainActor
struct RemoteVoiceTransmitOrderTests {
    private struct PlaybackFailed: LocalizedError { var errorDescription: String? { "Playback failed" } }

    @Test func playbackFailureNeverKeysAndStopsTheMic() {
        var events: [String] = []
        let failure = RemoteVoiceController.beginTransmit(
            startMic: { events.append("mic on") },
            stopMic: { events.append("mic off") },
            startPlayback: { throw PlaybackFailed() },
            key: { events.append("key") })
        #expect(failure == "Playback failed")
        #expect(events == ["mic on", "mic off"])
    }

    @Test func keysOnlyAfterPlaybackStarted() {
        var events: [String] = []
        let failure = RemoteVoiceController.beginTransmit(
            startMic: { events.append("mic on") },
            stopMic: { events.append("mic off") },
            startPlayback: { events.append("playback") },
            key: { events.append("key") })
        #expect(failure == nil)
        #expect(events == ["mic on", "playback", "key"])
    }

    @Test func timeLimitIsBelowTheAuthorityBackstop() {
        #expect(RemoteVoiceController.maxTransmitSeconds == 180)
        #expect(RemoteVoiceController.maxTransmitSeconds < PTTOwner.voice.maxKeySeconds)
        #expect(PTTOwner.voice.maxKeySeconds <= PTTAuthority.globalMaxKeySeconds)
    }
}

// MARK: - rigctld server: T 1 after a forced release

@MainActor
struct RigctldKeyRequestTests {
    @Test func firstKeyKeys() {
        #expect(RigctldServer.keyRequest(from: 1, keyingClient: nil, serverKeyed: false) == .key)
    }

    @Test func sameClientStillKeyedIsAlreadyKeyed() {
        #expect(RigctldServer.keyRequest(from: 1, keyingClient: 1, serverKeyed: true) == .alreadyKeyed)
    }

    @Test func anotherClientIsRefusedWhileTheKeyIsUp() {
        #expect(RigctldServer.keyRequest(from: 2, keyingClient: 1, serverKeyed: true) == .busy)
    }

    @Test func forcedReleaseMeansANewKeyNotAFalseSuccess() {
        // The authority took the server's key away (FT4, packet or voice may hold the
        // transmitter now): `T 1` must try to key — and be refused there — not answer OK.
        #expect(RigctldServer.keyRequest(from: 1, keyingClient: 1, serverKeyed: false) == .key)
        #expect(RigctldServer.keyRequest(from: 2, keyingClient: 1, serverKeyed: false) == .key)
    }
}
