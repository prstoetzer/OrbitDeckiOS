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
                Text("Decodes SSTV from your USB (or network) audio interface. Saved images appear on the Log screen. Foreground only.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
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

/// Dedicated gallery of decoded SSTV images (kept out of the QSO log). Tap to view.
struct SSTVGalleryScreen: View {
    @EnvironmentObject private var qso: QSOStore
    @State private var viewing: SSTVImageEntry?

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
                            Button { viewing = s } label: { thumb(s) }.buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { qso.deleteSSTVImage(s) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("SSTV Images")
        .sheet(item: $viewing) { SSTVViewer(entry: $0) }
    }

    private func thumb(_ s: SSTVImageEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let img = UIImage(contentsOfFile: QSOStore.sstvDir.appendingPathComponent(s.filename).path) {
                Image(uiImage: img).resizable().scaledToFit().cornerRadius(6)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(ODTheme.panel).frame(height: 110)
                    .overlay(Image(systemName: "photo").foregroundStyle(ODTheme.muted))
            }
            Text("\(s.mode.isEmpty ? "SSTV" : s.mode)\(s.sat.isEmpty ? "" : " · \(s.sat)")")
                .font(.caption2.weight(.semibold)).lineLimit(1)
            Text(ODFormat.primaryClock(s.date)).font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }
}

/// Full-screen viewer for a saved SSTV image, with export to Photos + share.
struct SSTVViewer: View {
    let entry: SSTVImageEntry
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    private var url: URL { QSOStore.sstvDir.appendingPathComponent(entry.filename) }
    private var uiImage: UIImage? { UIImage(contentsOfFile: url.path) }

    var body: some View {
        NavigationStack {
            VStack {
                if let img = uiImage {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                }
            }
            .navigationTitle("\(entry.mode.isEmpty ? "SSTV" : entry.mode)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { saveToPhotos() } label: {
                        Label(saved ? "Saved" : "Save to Photos", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }.disabled(saved || uiImage == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
    }

    private func saveToPhotos() {
        guard let img = uiImage else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        saved = true
    }
}
