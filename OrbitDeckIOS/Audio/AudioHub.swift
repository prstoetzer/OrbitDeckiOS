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
    func refresh() {
        let s = AVAudioSession.sharedInstance()
        let inRoute = s.currentRoute.inputs.contains { $0.portType == .usbAudio }
        let inAvail = (s.availableInputs ?? []).contains { $0.portType == .usbAudio }
        usbConnected = inRoute || inAvail
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
