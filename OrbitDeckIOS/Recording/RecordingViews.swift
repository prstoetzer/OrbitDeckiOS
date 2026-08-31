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
                AudioLevelControl(title: "Recording level", gain: $recorder.inputGain, level: recorder.level)
                Text("Records the received audio from your USB (or network) audio interface, tagged with the satellite and time. Set the level so the meter rides in the green. Works only in the foreground.")
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
                    if !voice.pttOverCAT {
                        Text("No CAT PTT on this radio — use VOX, or the TRANSMIT button just sends mic audio.")
                            .font(.caption2).foregroundStyle(ODTheme.muted)
                    }
                }

                Text("Listen to the radio and hold TRANSMIT to talk — an SSB QSO through the phone over your Icom network (RS-BA1) radio. Use earphones to avoid feedback. Experimental: validate the network audio on your radio.")
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
