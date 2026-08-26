import Foundation
import AVFoundation
import Combine

// ===========================================================================
//  AudioHub.swift — audio availability + source vending
//
//  Tracks whether an audio interface is present (a USB audio interface, or a
//  configured+connected Icom network-audio radio) and vends the active
//  `AudioSource`. `audioAvailable` is the gate for the FT4 / SSTV / pass-recording
//  Home cards (they appear only when audio is present). Observes
//  `AVAudioSession.routeChangeNotification` so plugging/unplugging updates live.
// ===========================================================================

@MainActor
final class AudioHub: ObservableObject {
    /// A USB audio interface is connected (input port present).
    @Published private(set) var usbConnected = false
    /// An Icom network-audio radio is configured and connected (Phase 7).
    @Published private(set) var icomAudioReady = false

    /// The gate for the audio-feature Home cards.
    var audioAvailable: Bool { usbConnected || icomAudioReady }

    private weak var rig: RigController?
    private var cancellables = Set<AnyCancellable>()

    func attach(_ rig: RigController) {
        self.rig = rig
        // Put the session in a record-capable category (without activating it) so
        // `availableInputs` enumerates a USB audio *input* even before we record.
        // `.mixWithOthers` avoids interrupting any other audio; no mic prompt occurs
        // until we actually capture.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .measurement,
                                                         options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Recompute when the rig connects/disconnects (Icom network audio path).
        rig.$connected.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }.store(in: &cancellables)
        refresh()
    }

    /// Recompute availability. Called on route changes and when rig state changes.
    /// A USB audio interface may present as an input, an output (system audio is
    /// routed to it), or an available input — check all three so a bidirectional
    /// adapter is detected even when we're not recording.
    func refresh() {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        let inRoute = route.inputs.contains { $0.portType == .usbAudio }
        let outRoute = route.outputs.contains { $0.portType == .usbAudio }
        let inAvail = (s.availableInputs ?? []).contains { $0.portType == .usbAudio }
        usbConnected = inRoute || outRoute || inAvail
        // Icom network audio is available when a configured radio uses the RS-BA1
        // network transport and is connected (EXPERIMENTAL path).
        icomAudioReady = rig?.icomAudioTransport != nil
    }

    /// The active audio source, preferring a USB interface, else Icom network audio.
    func makeSource() -> AudioSource? {
        if usbConnected { return USBAudioSource() }
        if let t = rig?.icomAudioTransport { return IcomAudioSource(transport: t) }
        return nil
    }
}
