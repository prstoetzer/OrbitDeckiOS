import SwiftUI

// ===========================================================================
//  RecordingViews.swift — Home pass-recording card
//
//  Shown only when an audio interface is available (USB, or later Icom network
//  audio) — the Phase 9 gate. Records the received audio for the selected
//  satellite; clips are listed on the Log screen.
// ===========================================================================

struct HomeRecordingCard: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var recorder: PassRecorder
    @AppStorage(FeatureVisibility.recorderKey) private var visibility = FeatureVisibility.auto
    let satellite: SatelliteRecord

    private var visible: Bool {
        switch visibility { case .auto: audio.audioAvailable; case .always: true; case .off: false }
    }

    var body: some View {
        if visible {
            SectionCard("Pass recording") {
                AudioHealthBanner(active: recorder.isRecording)
                if !recorder.errorText.isEmpty {
                    Text(recorder.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(recorder.isRecording ? ODTheme.warning : ODTheme.muted)
                        .frame(width: 10, height: 10)
                    Text(recorder.isRecording ? ODFormat.duration(recorder.elapsed) : "Ready")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                    Spacer()
                    Button(recorder.isRecording ? "Stop" : "Record") { toggle() }
                        .buttonStyle(.bordered)
                        .tint(recorder.isRecording ? ODTheme.warning : ODTheme.accent)
                }
                SatelliteStatusLine(satellite: satellite)
                LiveMetersReader(meters: recorder.meters) { m in
                    AudioLevelControl(title: "Recording level", gain: $recorder.inputGain, level: m.level)
                }
                VoiceMemoControl(satellite: satellite)
                Text("Records the received audio from your USB (or network) audio interface, tagged with the satellite and time. Set the level so the meter rides in the green. Keeps recording with the screen locked or the app backgrounded during a pass.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private func toggle() {
        if recorder.isRecording {
            recorder.stop()
        } else if let source = audio.makeSource(allowMicFallback: visibility == .always) {
            recorder.start(source: source, satellite: satellite.name)
        } else {
            recorder.errorText = "No audio interface available."
        }
    }
}

// ===========================================================================
//  HomeRemoteAudioCard — listen to the radio and talk (SSB voice) through the app
//
//  Network (RS-BA1) radios only: the radio's audio plays on the phone and the phone
//  mic transmits, with PTT keyed over CAT. Shares the AudioHub capture, so pass
//  recording can run alongside; it's mutually exclusive with FT4/SSTV. EXPERIMENTAL —
//  the RS-BA1 audio path is not yet hardware-validated.
// ===========================================================================
struct HomeRemoteAudioCard: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var voice: RemoteVoiceController
    @AppStorage(FeatureVisibility.remoteAudioKey) private var visibility = FeatureVisibility.auto
    let satellite: SatelliteRecord

    private var visible: Bool {
        switch visibility {
        case .auto: audio.icomAudioReady          // network radio audio present
        case .always: true
        case .off: false
        }
    }

    var body: some View {
        if visible {
            SectionCard("Remote audio (voice)") {
                if !voice.errorText.isEmpty {
                    Text(voice.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(statusColor).frame(width: 10, height: 10)
                    Text(voice.isTransmitting ? "Transmitting" : (voice.isListening ? "Listening…" : "Off"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(voice.isListening ? "Stop" : "Listen") {
                        voice.isListening ? voice.stopListen() : voice.startListen()
                    }
                    .buttonStyle(.bordered)
                    .tint(voice.isListening ? ODTheme.warning : ODTheme.accent)
                }
                SatelliteStatusLine(satellite: satellite)

                if voice.isListening {
                    AudioLevelBar(level: voice.micLevel)
                    pttButton
                    if let why = voice.pttBlockedReason {
                        Text(why).font(.caption2).foregroundStyle(ODTheme.warning)
                    } else if !voice.pttOverCAT {
                        Text("No CAT PTT on this radio — use VOX, or the TRANSMIT button just sends mic audio.")
                            .font(.caption2).foregroundStyle(ODTheme.muted)
                    }
                }

                Text("Listen to the radio and hold TRANSMIT to talk — an SSB or FM voice QSO through the phone over your Icom network (RS-BA1) radio. Network only: with a USB interface iOS can capture just one input at a time (the USB input is the radio's receive audio), so the phone mic isn't available to transmit. Use earphones to avoid feedback. Experimental: validate the network audio on your radio.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    private var statusColor: Color {
        if voice.isTransmitting { return ODTheme.warning }
        if voice.isListening { return ODTheme.good }
        return ODTheme.muted
    }

    /// Hold-to-talk: press starts TX, release ends it.
    private var pttButton: some View {
        Text(voice.isTransmitting ? "ON AIR — release to stop" : "HOLD TO TRANSMIT")
            .font(.callout.weight(.bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(voice.isTransmitting ? ODTheme.warning : ODTheme.accent.opacity(0.15))
            .foregroundStyle(voice.isTransmitting ? .white : ODTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ODTheme.accent.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !voice.isTransmitting { voice.startTX() } }
                    .onEnded { _ in voice.stopTX() }
            )
    }
}

// ===========================================================================
//  VoiceMemoControl — record a quick spoken note with a QSO stub
//
//  Used on the pass-recording card and the Log screen. Records through the shared
//  AudioHub capture (built-in mic allowed: memos are spoken by the operator) up to
//  PassRecorder.memoCap, then saves the clip with the recordings and logs a QSO stub
//  — UTC time, satellite, transponder mode and frequencies, no callsign — linked to
//  it, to be completed after the pass.
// ===========================================================================
struct VoiceMemoControl: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var qso: QSOStore
    @ObservedObject private var memo = PassRecorder.memo
    /// The satellite to tag the memo with; nil uses the selected satellite.
    var satellite: SatelliteRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Button { toggle() } label: {
                    Label(memo.isRecording ? "Stop memo" : "Voice memo",
                          systemImage: memo.isRecording ? "stop.circle.fill" : "mic.circle")
                }
                .buttonStyle(.bordered)
                .tint(memo.isRecording ? ODTheme.warning : ODTheme.accent)
                if memo.isRecording {
                    Text("\(ODFormat.duration(memo.elapsed)) / \(ODFormat.duration(PassRecorder.memoCap))")
                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.warning)
                        .fixedSize()
                    LiveMetersReader(meters: memo.meters) { m in AudioLevelBar(level: m.level) }
                }
            }
            if !memo.errorText.isEmpty {
                Text(memo.errorText).font(.caption).foregroundStyle(ODTheme.warning)
            }
            Text("Speak a note (up to \(Int(PassRecorder.memoCap / 60)) min); it's saved with your recordings and a QSO stub with the time, satellite, mode and frequencies is added to the Log for you to complete later. Uses the built-in mic or a headset — or, with a USB audio interface connected, that interface's input.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    private func toggle() {
        Self.toggle(satellite: satellite ?? store.selectedSatellite, audio: audio, store: store, rig: rig, qso: qso)
    }

    /// Start or stop the voice memo (shared with the Log screen's toolbar action).
    static func toggle(satellite sat: SatelliteRecord?, audio: AudioHub, store: OrbitStore,
                       rig: RigController, qso: QSOStore) {
        let memo = PassRecorder.memo
        if memo.isRecording { memo.stop(); return }
        guard let source = audio.makeSource(allowMicFallback: true) else {
            memo.errorText = "No audio input available."
            return
        }
        var stub = QSORecord.prefilled(satellite: sat, transponder: sat.flatMap { rig.transponder(for: $0) },
                                       myGrid: store.operatorGrid6, myCall: qso.config.myCall,
                                       defaultRst: qso.config.defaultRst)
        if let sat, rig.config.tuning.linearCW, rig.transponder(for: sat)?.isLinear ?? false {
            stub.mode = "CW"; stub.uplinkMode = nil; stub.downlinkMode = nil
            stub.rstSent = qso.config.rst(for: "CW"); stub.rstRcvd = stub.rstSent
        }
        memo.startMemo(source: source, qso: qso, stub: stub)
    }
}
