import Testing
import Foundation
import Network
@testable import OrbitDeck

// MARK: - Rotator failed-send retry, and rigctld/rotctld client approval
//
// `RotatorSendGate`: a failed point keeps the deadband reference and is retried after a
// growing backoff; a delivered point inside the deadband isn't resent. And the
// `NetworkServerApprovals` state machine: pending, allow once / always / deny, timeout,
// loopback, background, and the VPN-interface filter.

struct RotatorSendGateTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func wants(_ g: RotatorSendGate, az: Double, el: Double = 30, keepalive: Double? = nil,
                       at seconds: Double) -> Bool {
        g.shouldSend(az: az, el: el, deadband: 2, azimuthOnly: false, keepaliveSec: keepalive,
                     now: t0.addingTimeInterval(seconds))
    }

    @Test func failedPointIsRetriedAfterBackoff() {
        var g = RotatorSendGate()
        #expect(wants(g, az: 100, at: 0))                    // nothing sent yet
        g.recordFailure(now: t0)
        #expect(g.lastAz == nil)                             // the failure didn't become the reference
        #expect(!wants(g, az: 100, at: 1))                   // backing off
        #expect(wants(g, az: 100, at: 2))                    // same (fixed/GEO) target retried
        g.recordFailure(now: t0.addingTimeInterval(2))
        #expect(!wants(g, az: 100, at: 5.9))                 // second failure: 4 s
        #expect(wants(g, az: 100, at: 6))
        g.recordSuccess(az: 100, el: 30, now: t0.addingTimeInterval(6))
        #expect(g.failures == 0 && g.retryAt == nil)
        #expect(!wants(g, az: 100, at: 60))                  // delivered: not resent
    }

    @Test func successInsideDeadbandIsNotResent() {
        var g = RotatorSendGate()
        g.recordSuccess(az: 100, el: 30, now: t0)
        #expect(!wants(g, az: 101, el: 31, at: 1))           // inside the 2° deadband
        #expect(wants(g, az: 102, at: 1))                    // moved past it
        #expect(wants(g, az: 100, el: 32, at: 1))
    }

    @Test func failureKeepsTheLastDeliveredReference() {
        var g = RotatorSendGate()
        g.recordSuccess(az: 10, el: 5, now: t0)
        g.recordFailure(now: t0.addingTimeInterval(1))       // the point at az 20 didn't go out
        #expect(g.lastAz == 10 && g.lastEl == 5)
        #expect(g.lastSendAt == t0)
    }

    @Test func backoffGrowsToTenSeconds() {
        #expect([1, 2, 3, 4, 5, 9].map { RotatorSendGate.backoff(failures: $0) } == [2, 4, 8, 10, 10, 10])
    }

    @Test func pstRotatorKeepaliveStillResends() {
        var g = RotatorSendGate()
        g.recordSuccess(az: 100, el: 30, now: t0)
        #expect(!wants(g, az: 100, keepalive: 2, at: 1.5))
        #expect(wants(g, az: 100, keepalive: 2, at: 2))
        #expect(!wants(g, az: 100, keepalive: nil, at: 30))  // reliable transports: movement only
    }

    @Test func resetDropsBackoffForANewTarget() {
        var g = RotatorSendGate()
        g.recordFailure(now: t0)
        #expect(!wants(g, az: 200, at: 0.5))
        g.reset()
        #expect(wants(g, az: 200, at: 0.5))
    }
}

@MainActor
struct NetworkServerApprovalTests {
    private let defaults: UserDefaults

    init() {
        let suite = "orbitdeck.tests.approvals.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(background: Bool = false) -> NetworkServerApprovals {
        NetworkServerApprovals(defaults: defaults, timeout: 30, isInBackground: { background })
    }

    /// Collects the decisions delivered to a waiting client.
    private final class Outcome {
        var values: [Bool] = []
    }

    private func admit(_ m: NetworkServerApprovals, _ kind: HamlibServerKind = .rigctld, client: Int = 1,
                       address: String = "192.168.1.20", loopback: Bool = false,
                       into outcome: Outcome) -> NetworkServerApprovals.Admission {
        m.admit(kind, client: client, address: address, loopback: loopback) { outcome.values.append($0) }
    }

    @Test func newAddressIsHeldPending() {
        let m = model(), o = Outcome()
        #expect(m.requireApproval)                           // on by default
        #expect(admit(m, into: o) == .pending)
        #expect(m.pending.map(\.address) == ["192.168.1.20"])
        #expect(m.pending.first?.kind == .rigctld)
        #expect(o.values.isEmpty)
    }

    @Test func allowOnceAdmitsButAsksAgainNextTime() {
        let m = model(), o = Outcome()
        _ = admit(m, into: o)
        m.allowOnce(m.pending[0])
        #expect(o.values == [true] && m.pending.isEmpty && m.allowlist.isEmpty)
        #expect(admit(m, client: 2, into: Outcome()) == .pending)
    }

    @Test func alwaysAllowPersistsAndAutoApproves() {
        let m = model(), o = Outcome()
        _ = admit(m, .rotctld, into: o)
        m.alwaysAllow(m.pending[0])
        #expect(o.values == [true])
        let reloaded = model()                               // a later launch
        #expect(reloaded.allowlist.map(\.address) == ["192.168.1.20"])
        #expect(admit(reloaded, .rotctld, client: 7, into: Outcome()) == .allowed)
        // Per server: allowing the rotator doesn't allow the radio.
        #expect(admit(reloaded, .rigctld, client: 8, into: Outcome()) == .pending)
        reloaded.removeFromAllowlist(reloaded.allowlist[0])
        #expect(admit(model(), .rotctld, client: 9, into: Outcome()) == .pending)
    }

    @Test func denyClosesEveryConnectionFromThatAddress() {
        let m = model(), a = Outcome(), b = Outcome()
        _ = admit(m, client: 1, into: a)
        _ = admit(m, client: 2, into: b)                     // same address: one request
        #expect(m.pending.count == 1)
        m.deny(m.pending[0])
        #expect(a.values == [false] && b.values == [false] && m.pending.isEmpty)
    }

    @Test func unansweredRequestTimesOut() {
        let m = model(), o = Outcome()
        _ = admit(m, into: o)
        let since = m.pending[0].since
        m.expireStale(now: since.addingTimeInterval(29))
        #expect(o.values.isEmpty && m.pending.count == 1)
        m.expireStale(now: since.addingTimeInterval(30))
        #expect(o.values == [false] && m.pending.isEmpty)
    }

    @Test func loopbackIsAllowedAutomatically() {
        let m = model(), o = Outcome()
        #expect(admit(m, address: "127.0.0.1", loopback: true, into: o) == .allowed)
        #expect(m.pending.isEmpty && o.values.isEmpty)
    }

    @Test func backgroundDeniesNewAndPendingRequests() {
        #expect(admit(model(background: true), into: Outcome()) == .denied)
        let m = model(), o = Outcome()
        _ = admit(m, into: o)
        m.denyAllPending(reason: "test")
        #expect(o.values == [false] && m.pending.isEmpty)
    }

    @Test func disconnectWithdrawsTheRequest() {
        let m = model(), o = Outcome()
        _ = admit(m, client: 4, into: o)
        m.cancel(.rotctld, client: 4)                        // another server's client 4: no effect
        #expect(m.pending.count == 1)
        m.cancel(.rigctld, client: 4)
        #expect(m.pending.isEmpty && o.values.isEmpty)
    }

    @Test func turningApprovalOffAdmitsWaitingClientsAndPersists() {
        let m = model(), o = Outcome()
        _ = admit(m, into: o)
        m.setRequireApproval(false)
        #expect(o.values == [true] && m.pending.isEmpty)
        #expect(!model().requireApproval)
        #expect(admit(model(), client: 3, into: Outcome()) == .allowed)
    }

    @Test func vpnAndCellularInterfacesAreNotLAN() {
        #expect(HamlibProtocol.isLANInterface(name: "en0", type: .wifi))
        #expect(HamlibProtocol.isLANInterface(name: "en5", type: .wiredEthernet))
        #expect(HamlibProtocol.isLANInterface(name: "lo0", type: .loopback))
        #expect(HamlibProtocol.isLANInterface(name: "bridge100", type: .other))   // Personal Hotspot
        #expect(!HamlibProtocol.isLANInterface(name: "utun3", type: .other))
        #expect(!HamlibProtocol.isLANInterface(name: "ipsec0", type: .other))
        #expect(!HamlibProtocol.isLANInterface(name: "pdp_ip0", type: .cellular))
    }

    @Test func peerAddressAndLoopbackDetection() {
        let mapped = NWEndpoint.hostPort(host: .ipv6(IPv6Address("::ffff:192.168.1.20")!), port: 4532)
        #expect(HamlibProtocol.peerAddress(mapped) == "192.168.1.20")
        #expect(HamlibProtocol.isLoopbackPeer(.hostPort(host: .ipv4(IPv4Address("127.0.0.1")!), port: 4532)))
        #expect(HamlibProtocol.isLoopbackPeer(.hostPort(host: .ipv6(.loopback), port: 4532)))
        #expect(!HamlibProtocol.isLoopbackPeer(.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 4532)))
    }
}
