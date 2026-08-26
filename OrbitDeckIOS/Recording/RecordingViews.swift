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
                if recorder.isRecording {
                    ProgressView(value: Double(min(1, recorder.level)))
                        .tint(ODTheme.good)
                }
                Text("Records the received audio from your USB (or network) audio interface, tagged with the satellite and time. Works only in the foreground.")
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
