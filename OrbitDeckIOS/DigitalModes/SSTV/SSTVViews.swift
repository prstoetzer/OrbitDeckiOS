import SwiftUI
import UIKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

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
    @AppStorage(FeatureVisibility.sstvKey) private var visibility = FeatureVisibility.auto
    @State private var showSetup = false
    let satellite: SatelliteRecord

    private var visible: Bool {
        switch visibility { case .auto: audio.audioAvailable; case .always: true; case .off: false }
    }

    var body: some View {
        if visible {
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
                SatelliteStatusLine(satellite: satellite)
                DopplerFrequencyLine(satellite: satellite)
                if let img = decoder.image {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxHeight: 240).cornerRadius(6)
                }

                Picker("Mode", selection: Binding(
                    get: { decoder.manualMode?.name ?? "" },
                    set: { name in decoder.manualMode = SSTVModes.all.first { $0.name == name } }
                )) {
                    Text("Auto-detect (VIS)").tag("")
                    ForEach(SSTVModes.all) { m in Text(m.name).tag(m.name) }
                }
                .disabled(decoder.isListening)

                // Level meter + calibration tucked into a disclosure so the card stays
                // uncluttered (mirrors the FT4 card).
                DisclosureGroup("Setup & calibration", isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 8) {
                        // Always available so the operator can set the level before decoding
                        // (persisted across launches); the meter reads 0 until listening.
                        AudioLevelControl(title: "Input level", gain: $decoder.inputGain, level: decoder.inputLevel)
                        Text("SSTV is FM — level doesn't set the colors, but keep the meter out of the red and off the floor for a clean decode.")
                            .font(.caption2).foregroundStyle(ODTheme.muted)
                        compensation
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline).tint(ODTheme.accent)

                Text("Decodes SSTV live from your USB (or network) audio interface — the image builds as it receives. Saved images appear on the SSTV Images screen. Keeps decoding with the screen locked or the app backgrounded during a pass.")
                    .font(.caption2).foregroundStyle(ODTheme.muted)
            }
        }
    }

    /// Slant + tuning calibration sliders (like MMSSTV / Robot36). Adjustments
    /// re-decode the current image live from the retained sample buffer.
    private var compensation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $decoder.autoTune) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-tune (Doppler)").font(.caption2)
                    Text("Tracks the sync pulse to follow satellite Doppler; Tuning below is an added trim.")
                        .font(.caption2).foregroundStyle(ODTheme.muted)
                }
            }
            .toggleStyle(.switch)
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
            HStack {
                Text("H-shift").font(.caption2).foregroundStyle(ODTheme.muted).frame(width: 62, alignment: .leading)
                Spacer()
                Text(String(format: "%+.1f ms", decoder.hShiftMs)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $decoder.hShiftMs, range: -60...60, step: 0.5)
            HStack {
                Text("Contrast").font(.caption2).foregroundStyle(ODTheme.muted).frame(width: 62, alignment: .leading)
                Spacer()
                Text(String(format: "%.2f×", decoder.contrast)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $decoder.contrast, range: 0.5...2.5, step: 0.05)
            HStack {
                Text("Saturation").font(.caption2).foregroundStyle(ODTheme.muted).frame(width: 62, alignment: .leading)
                Spacer()
                Text(String(format: "%.2f×", decoder.saturation)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $decoder.saturation, range: 0...2.5, step: 0.05)
            Button("Reset calibration") {
                decoder.slant = 0; decoder.tuningHz = 0; decoder.hShiftMs = 0
                decoder.contrast = 1; decoder.saturation = 1
            }
            .font(.caption2).buttonStyle(.borderless)
        }
    }

    private func toggle() {
        if decoder.isListening {
            decoder.stop()
        } else if let source = audio.makeSource(allowMicFallback: visibility == .always) {
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
            Text(ODFormat.utcStamp(s.date)).font(.caption2).foregroundStyle(ODTheme.muted)
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
    @State private var editing = false
    @State private var reDecoding = false

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
                Button { editing = true } label: {
                    Label("Fix image (slant / color)", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).disabled(uiImage == nil)
                if entry.audioFile != nil {
                    Button { reDecoding = true } label: {
                        Label("Re-decode from recording", systemImage: "waveform.badge.magnifyingglass").frame(maxWidth: .infinity)
                    }
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
            .sheet(isPresented: $editing) { SSTVImageEditor(entry: entry) }
            .sheet(isPresented: $reDecoding) { SSTVReDecodeView(entry: entry) }
        }
    }

    private func saveToPhotos() {
        guard let img = uiImage else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        saved = true
    }
}

/// Post-decode raster fix-up for a saved SSTV image: straighten the diagonal slant
/// (a horizontal shear that grows down the image), nudge the picture left/right, and
/// adjust brightness/contrast/saturation. Non-destructive — writes a new image so the
/// original is kept. (Geometry + cosmetic only; the Doppler frequency-offset color
/// cast is a demod-domain error and is fixed instead by the live auto-tune / the
/// re-decode-from-recording path.)
struct SSTVImageEditor: View {
    let entry: SSTVImageEntry
    @EnvironmentObject private var qso: QSOStore
    @Environment(\.dismiss) private var dismiss

    @State private var slantPx: Double = 0      // horizontal shift, top→bottom, in pixels
    @State private var hShiftPx: Double = 0
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var preview: UIImage?

    private let ciContext = CIContext(options: nil)
    private var srcURL: URL { QSOStore.sstvDir.appendingPathComponent(entry.filename) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let p = preview {
                        Image(uiImage: p).resizable().scaledToFit().cornerRadius(6)
                    } else {
                        ContentUnavailableView("Image unavailable", systemImage: "photo")
                    }
                    controls
                }
                .padding()
            }
            .navigationTitle("Fix Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Copy") { saveCopy() }.disabled(preview == nil)
                }
            }
            .onAppear(perform: render)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            slider("Slant", $slantPx, -160...160, "%+.0f px")
            slider("H-shift", $hShiftPx, -160...160, "%+.0f px")
            slider("Brightness", $brightness, -0.5...0.5, "%+.2f")
            slider("Contrast", $contrast, 0.4...2.2, "%.2f×")
            slider("Saturation", $saturation, 0...2.2, "%.2f×")
            Button("Reset") {
                slantPx = 0; hShiftPx = 0; brightness = 0; contrast = 1; saturation = 1; render()
            }
            .font(.caption).buttonStyle(.borderless)
        }
    }

    private func slider(_ name: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.caption2).foregroundStyle(ODTheme.muted)
                Spacer()
                Text(String(format: fmt, v.wrappedValue)).font(.caption2.monospacedDigit())
            }
            Slider(value: v, in: range) { editing in if !editing { render() } }
        }
    }

    private func render() {
        guard let ui = UIImage(contentsOfFile: srcURL.path), let cg = ui.cgImage else { preview = nil; return }
        let ci = CIImage(cgImage: cg)
        let extent = ci.extent
        let color = CIFilter.colorControls()
        color.inputImage = ci
        color.brightness = Float(brightness)
        color.contrast = Float(contrast)
        color.saturation = Float(saturation)
        var out = color.outputImage ?? ci
        // Shear x proportional to row + horizontal offset. CIImage is bottom-left origin
        // (y up), so the shear coefficient is negated to act top→bottom like the picture.
        let k = extent.height > 0 ? slantPx / Double(extent.height) : 0
        out = out.transformed(by: CGAffineTransform(a: 1, b: 0, c: CGFloat(-k), d: 1, tx: CGFloat(hShiftPx), ty: 0))
        out = out.cropped(to: extent)
        guard let rendered = ciContext.createCGImage(out, from: extent) else { preview = nil; return }
        preview = UIImage(cgImage: rendered)
    }

    private func saveCopy() {
        guard let p = preview, let data = p.pngData() else { return }
        let name = "SSTV_\(Int(Date().timeIntervalSince1970))_fixed.png"
        let dst = QSOStore.sstvDir.appendingPathComponent(name)
        do {
            try data.write(to: dst)
            let mode = entry.mode.isEmpty ? "SSTV (fixed)" : "\(entry.mode) (fixed)"
            qso.addSSTVImage(SSTVImageEntry(sat: entry.sat, date: Date(), mode: mode, filename: name))
            dismiss()
        } catch {}
    }
}

/// Re-decode a saved image from its captured pass audio with different slant / auto-tune.
/// Unlike the raster editor this re-runs the full demodulator, so it can recover the
/// Doppler color cast as well as geometry. Non-destructive: saves a new image (which
/// references the same recording, so it can be re-decoded again).
struct SSTVReDecodeView: View {
    let entry: SSTVImageEntry
    @EnvironmentObject private var qso: QSOStore
    @Environment(\.dismiss) private var dismiss

    @State private var slantPct: Double = 0        // ±% clock trim
    @State private var tuningHz: Double = 0
    @State private var autoTune = true
    @State private var preview: UIImage?
    @State private var decodedMode = ""
    @State private var working = false
    @State private var failed = false

    private var audioURL: URL? { entry.audioFile.map { QSOStore.sstvDir.appendingPathComponent($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let p = preview {
                        Image(uiImage: p).resizable().scaledToFit().cornerRadius(6)
                        if !decodedMode.isEmpty { Text(decodedMode).font(.caption).foregroundStyle(ODTheme.muted) }
                    } else if working {
                        ProgressView("Decoding…").frame(maxWidth: .infinity, minHeight: 160)
                    } else if failed {
                        ContentUnavailableView("Couldn't decode", systemImage: "waveform.slash",
                                               description: Text("No SSTV image was found in the recording."))
                    } else {
                        ContentUnavailableView("Re-decode", systemImage: "waveform.badge.magnifyingglass",
                                               description: Text("Adjust and tap Decode to rebuild the image from the recorded pass audio."))
                    }
                    controls
                }
                .padding()
            }
            .navigationTitle("Re-decode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Copy") { saveCopy() }.disabled(preview == nil)
                }
            }
            .onAppear { decode() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto-tune (Doppler)", isOn: $autoTune).font(.caption2).toggleStyle(.switch)
            HStack {
                Text("Slant").font(.caption2).foregroundStyle(ODTheme.muted)
                Spacer(); Text(String(format: "%+.3f%%", slantPct)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $slantPct, range: -2...2, step: 0.05)
            HStack {
                Text("Tuning").font(.caption2).foregroundStyle(ODTheme.muted)
                Spacer(); Text(String(format: "%+.0f Hz", tuningHz)).font(.caption2.monospacedDigit())
            }
            FineSlider(value: $tuningHz, range: -400...400, step: 5)
            Button(working ? "Decoding…" : "Decode") { decode() }
                .buttonStyle(.borderedProminent).disabled(working)
        }
    }

    private func decode() {
        guard let url = audioURL, !working else { return }
        working = true; failed = false
        let slant = slantPct / 100.0, tuning = tuningHz, auto = autoTune
        let startSec = entry.audioStartSec ?? 0
        Task.detached {
            let result: (image: UIImage, mode: String)? = {
                guard let file = try? AVAudioFile(forReading: url) else { return nil }
                let fmt = file.processingFormat
                let n = AVAudioFrameCount(file.length)
                guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n),
                      (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData else { return nil }
                let count = Int(buf.frameLength)
                // Skip to ~1 s before this image began (keeps its VIS header), so a session
                // that decoded several images re-decodes this one.
                let skip = max(0, min(count - 1, Int((startSec - 1.0) * fmt.sampleRate)))
                var samples = [Float](repeating: 0, count: count - skip)
                let p = ch[0]; for i in skip..<count { samples[i - skip] = p[i] }
                return SSTVDecoder().decodeOffline(frames: samples, rate: fmt.sampleRate, forced: nil,
                                                   slant: slant, autoTune: auto, tuning: tuning)
            }()
            await MainActor.run {
                working = false
                if let result { preview = result.image; decodedMode = result.mode; failed = false }
                else { preview = nil; failed = true }
            }
        }
    }

    private func saveCopy() {
        guard let p = preview, let data = p.pngData() else { return }
        let name = "SSTV_\(Int(Date().timeIntervalSince1970))_redecode.png"
        do {
            try data.write(to: QSOStore.sstvDir.appendingPathComponent(name))
            let mode = decodedMode.isEmpty ? "SSTV (re-decoded)" : "\(decodedMode) (re-decoded)"
            qso.addSSTVImage(SSTVImageEntry(sat: entry.sat, date: Date(), mode: mode, filename: name,
                                            audioFile: entry.audioFile, audioRate: entry.audioRate))
            dismiss()
        } catch {}
    }
}
