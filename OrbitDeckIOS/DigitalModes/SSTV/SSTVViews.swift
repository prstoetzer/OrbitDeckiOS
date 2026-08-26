import SwiftUI
import UIKit

// ===========================================================================
//  SSTVViews.swift — Home SSTV card + image viewer
//
//  The card (shown only when audio is available — Phase 9 gate) live-decodes the
//  received subcarrier into an image; decoded images are saved and listed on the
//  Log screen. The viewer can export an image to the iOS photo library.
// ===========================================================================

struct HomeSSTVCard: View {
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var decoder: SSTVDecoder
    let satellite: SatelliteRecord

    var body: some View {
        if audio.audioAvailable {
            SectionCard("SSTV") {
                if !decoder.errorText.isEmpty {
                    Text(decoder.errorText).font(.caption).foregroundStyle(ODTheme.warning)
                }
                HStack(spacing: 10) {
                    Circle().fill(decoder.isListening ? ODTheme.good : ODTheme.muted).frame(width: 10, height: 10)
                    Text(decoder.isListening ? (decoder.modeName.isEmpty ? "Listening…" : decoder.modeName) : decoder.status)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(decoder.isListening ? "Stop" : "Decode") { toggle() }
                        .buttonStyle(.bordered)
                }
                if let img = decoder.image {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxHeight: 240).cornerRadius(6)
                }

                if decoder.isListening {
                    AudioLevelControl(title: "Input level", gain: $decoder.inputGain, level: decoder.inputLevel)
                    Text("SSTV is FM — level doesn't set the colors, but keep the meter out of the red and off the floor for a clean decode.")
                        .font(.caption2).foregroundStyle(ODTheme.muted)
                }

                Picker("Mode", selection: Binding(
                    get: { decoder.manualMode?.name ?? "" },
                    set: { name in decoder.manualMode = SSTVModes.all.first { $0.name == name } }
                )) {
                    Text("Auto-detect (VIS)").tag("")
                    ForEach(SSTVModes.all) { m in Text(m.name).tag(m.name) }
                }
                .disabled(decoder.isListening)

                compensation

                Text("Decodes SSTV live from your USB (or network) audio interface — the image builds as it receives. Saved images appear on the SSTV Images screen. Foreground only.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// Slant + tuning calibration sliders (like MMSSTV / Robot36). Adjustments
    /// re-decode the current image live from the retained sample buffer.
    private var compensation: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Slant").font(.caption2).foregroundStyle(ODTheme.muted).frame(width: 46, alignment: .leading)
                Spacer()
                Text(String(format: "%+.3f%%", decoder.slant * 100))
                    .font(.caption2.monospacedDigit())
            }
            FineSlider(value: $decoder.slant, range: -0.02...0.02, step: 0.0005)
            HStack {
                Text("Tuning").font(.caption2).foregroundStyle(ODTheme.muted).frame(width: 46, alignment: .leading)
                Spacer()
                Text(String(format: "%+.0f Hz", decoder.tuningHz))
                    .font(.caption2.monospacedDigit())
            }
            FineSlider(value: $decoder.tuningHz, range: -400...400, step: 5)
            Button("Reset calibration") { decoder.slant = 0; decoder.tuningHz = 0 }
                .font(.caption2).buttonStyle(.borderless)
        }
    }

    private func toggle() {
        if decoder.isListening {
            decoder.stop()
        } else if let source = audio.makeSource() {
            decoder.start(source: source, satellite: satellite.name)
        } else {
            decoder.errorText = "No audio interface available."
        }
    }
}

/// Dedicated gallery of decoded SSTV images (kept out of the QSO log). Tap to view,
/// or use Select to choose several and delete them together.
struct SSTVGalleryScreen: View {
    @EnvironmentObject private var qso: QSOStore
    @State private var viewing: SSTVImageEntry?
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var confirmDelete = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8)]

    var body: some View {
        Group {
            if qso.sstvImages.isEmpty {
                ContentUnavailableView("No SSTV images yet", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Decode SSTV from the Home SSTV card (an audio interface must be connected). Saved images appear here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(qso.sstvImages) { s in
                            thumb(s)
                                .onTapGesture {
                                    if selecting { toggle(s) } else { viewing = s }
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle(selecting ? "\(selected.count) selected" : "SSTV Images")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !qso.sstvImages.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle(); selected.removeAll()
                    }
                }
                if selecting {
                    ToolbarItem(placement: .bottomBar) {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
        .sheet(item: $viewing) { SSTVViewer(entry: $0) }
        .confirmationDialog("Delete \(selected.count) image\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for s in qso.sstvImages where selected.contains(s.id) { qso.deleteSSTVImage(s) }
                selected.removeAll(); selecting = false
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func toggle(_ s: SSTVImageEntry) {
        if selected.contains(s.id) { selected.remove(s.id) } else { selected.insert(s.id) }
    }

    private func thumb(_ s: SSTVImageEntry) -> some View {
        let isSel = selected.contains(s.id)
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let img = UIImage(contentsOfFile: QSOStore.sstvDir.appendingPathComponent(s.filename).path) {
                    Image(uiImage: img).resizable().scaledToFit().cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(ODTheme.panel).frame(height: 110)
                        .overlay(Image(systemName: "photo").foregroundStyle(ODTheme.muted))
                }
                if selecting {
                    Image(systemName: isSel ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(isSel ? ODTheme.accent : .white)
                        .background(Circle().fill(.black.opacity(0.35)))
                        .padding(6)
                }
            }
            Text("\(s.mode.isEmpty ? "SSTV" : s.mode)\(s.sat.isEmpty ? "" : " · \(s.sat)")")
                .font(.caption2.weight(.semibold)).lineLimit(1)
            Text(ODFormat.primaryClock(s.date)).font(.caption2).foregroundStyle(ODTheme.muted)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ODTheme.accent, lineWidth: isSel ? 2 : 0))
    }
}

/// Full-screen viewer for a saved SSTV image, with export to Photos, share, and delete.
struct SSTVViewer: View {
    let entry: SSTVImageEntry
    @EnvironmentObject private var qso: QSOStore
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var confirmDelete = false

    private var url: URL { QSOStore.sstvDir.appendingPathComponent(entry.filename) }
    private var uiImage: UIImage? { UIImage(contentsOfFile: url.path) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let img = uiImage {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                }
                Spacer()
                // Clear, labeled actions instead of ambiguous toolbar icons.
                HStack(spacing: 10) {
                    Button { saveToPhotos() } label: {
                        Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(saved || uiImage == nil)

                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete image", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle(entry.mode.isEmpty ? "SSTV" : entry.mode)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete this image?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { qso.deleteSSTVImage(entry); dismiss() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func saveToPhotos() {
        guard let img = uiImage else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        saved = true
    }
}
