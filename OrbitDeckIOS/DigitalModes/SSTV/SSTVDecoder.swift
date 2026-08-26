import Foundation
import AVFoundation
import UIKit
import Combine

// ===========================================================================
//  SSTVDecoder.swift — SSTV receive decoder
//
//  Consumes an AudioSource, quadrature-FM-demodulates the 1500–2300 Hz video
//  subcarrier (1900 Hz center), detects the VIS header to pick the mode, then
//  walks the mode's segment table to reconstruct the image. Re-decodes the
//  growing buffer each tick for a live preview; saves the final image on stop.
//
//  Experimental: real signals need slant/tuning calibration — the timing model
//  is the standard nominal one. Flagged for on-air refinement.
// ===========================================================================

@MainActor
final class SSTVDecoder: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var image: UIImage?
    @Published private(set) var modeName = ""
    @Published private(set) var status = "Idle"
    @Published var errorText = ""

    private weak var qso: QSOStore?
    private var source: AudioSource?
    // Accessed from the background decode timer; guarded by `lock`.
    private nonisolated(unsafe) var rate: Double = 48_000
    private nonisolated(unsafe) var samples: [Float] = []
    private nonisolated(unsafe) let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private nonisolated(unsafe) var satName = ""

    func attach(_ qso: QSOStore) { self.qso = qso }

    func start(source: AudioSource, satellite: String) {
        guard !isListening else { return }
        errorText = ""; image = nil; modeName = ""; status = "Listening…"
        self.source = source; self.rate = source.sampleRate; self.satName = satellite
        lock.lock(); samples.removeAll(keepingCapacity: true); lock.unlock()
        do {
            try source.start(onFrames: { [weak self] frames in
                guard let self else { return }
                self.lock.lock(); self.samples.append(contentsOf: frames); self.lock.unlock()
            })
        } catch { errorText = error.localizedDescription; self.source = nil; return }
        isListening = true
        startDecodeTimer()
    }

    func stop() {
        guard isListening else { return }
        source?.stop(); source = nil
        timer?.cancel(); timer = nil
        isListening = false
        decodeOnce(final: true)
        status = image == nil ? "No image decoded" : "Decoded \(modeName)"
    }

    // MARK: Decode loop

    private func startDecodeTimer() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.decodeOnce(final: false) }
        t.resume()
        timer = t
    }

    private nonisolated func decodeOnce(final: Bool) {
        lock.lock(); let buf = samples; let r = rate; lock.unlock()
        guard buf.count > Int(r * 0.5) else { return }
        let freq = Self.demodulate(buf, rate: r)
        guard let vis = Self.findVIS(freq, rate: r), let mode = SSTVModes.mode(forVIS: vis.code) else { return }
        let img = Self.decodeImage(freq: freq, rate: r, mode: mode, start: vis.imageStart)
        Task { @MainActor in
            self.modeName = mode.name
            if let img { self.image = img; self.status = "Decoding \(mode.name)…" }
            if final, let img { self.save(img, mode: mode.name) }
        }
    }

    private func save(_ img: UIImage, mode: String) {
        guard let data = img.pngData() else { return }
        let name = "SSTV_\(Int(Date().timeIntervalSince1970)).png"
        let url = QSOStore.sstvDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            qso?.addSSTVImage(SSTVImageEntry(sat: satName, date: Date(), mode: mode, filename: name))
        } catch { errorText = "Could not save image: \(error.localizedDescription)" }
    }

    // MARK: DSP (nonisolated statics — run off the main actor)

    /// Quadrature FM demodulation to instantaneous frequency (Hz) per sample.
    nonisolated static func demodulate(_ x: [Float], rate: Double) -> [Double] {
        let center = 1900.0, w = 2.0 * Double.pi * center / rate
        var i = [Double](repeating: 0, count: x.count)
        var q = [Double](repeating: 0, count: x.count)
        for n in 0..<x.count {
            let ph = w * Double(n)
            i[n] = Double(x[n]) * cos(ph)
            q[n] = -Double(x[n]) * sin(ph)
        }
        // One-pole low-pass on I/Q to isolate the baseband.
        let a = 0.15
        var fi = 0.0, fq = 0.0
        for n in 0..<x.count { fi += a * (i[n] - fi); i[n] = fi; fq += a * (q[n] - fq); q[n] = fq }
        // Instantaneous frequency = center + phase derivative.
        var out = [Double](repeating: center, count: x.count)
        for n in 1..<x.count {
            let dphi = atan2(q[n] * i[n-1] - i[n] * q[n-1], i[n] * i[n-1] + q[n] * q[n-1])
            out[n] = center + dphi * rate / (2.0 * Double.pi)
        }
        return out
    }

    /// Find the VIS header; return its code and the sample index where the image
    /// starts (after the stop bit). Nominal timing: 300 ms 1900 Hz leader,
    /// 30 ms 1200 Hz start bit, 7×30 ms data bits (1100=1,1300=0, LSB first),
    /// parity, 30 ms stop bit.
    nonisolated static func findVIS(_ freq: [Double], rate: Double) -> (code: Int, imageStart: Int)? {
        let bit = Int(rate * 0.030)
        let leader = Int(rate * 0.100)     // require at least 100 ms of ~1900 Hz
        func avg(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(freq.count, b); guard hi > lo else { return 0 }
            var s = 0.0; for k in lo..<hi { s += freq[k] }; return s / Double(hi - lo)
        }
        var n = leader
        while n + 12 * bit < freq.count {
            // A leader (~1900) immediately followed by a 1200 Hz start bit.
            if abs(avg(n - leader, n) - 1900) < 80, abs(avg(n, n + bit) - 1200) < 90 {
                var start = n + bit
                var code = 0
                for b in 0..<7 {
                    let f = avg(start + b * bit, start + (b + 1) * bit)
                    if f < 1200 { code |= (1 << b) }     // 1100 Hz = 1
                }
                start += 8 * bit                          // 7 data + parity
                start += bit                              // stop bit
                return (code, start)
            }
            n += bit
        }
        return nil
    }

    /// Decode the image by walking the mode's segments.
    nonisolated static func decodeImage(freq: [Double], rate: Double, mode: SSTVMode, start: Int) -> UIImage? {
        let w = mode.width, h = mode.height
        var rgb = [UInt8](repeating: 0, count: w * h * 4)
        let lineSamples = mode.lineMs / 1000.0 * rate
        let transmittedLines = h / mode.linesPerScan

        func sampleValue(lineStart: Double, segOffsetMs: Double, segMs: Double, px: Int) -> Double {
            let tMs = segOffsetMs + (Double(px) + 0.5) / Double(w) * segMs
            let idx = Int(lineStart + tMs / 1000.0 * rate)
            guard idx >= 0, idx < freq.count else { return 0 }
            return max(0, min(1, (freq[idx] - 1500.0) / 800.0))
        }

        for tl in 0..<transmittedLines {
            let lineStart = Double(start) + Double(tl) * lineSamples
            if Int(lineStart) >= freq.count { break }
            // Gather channel scans for this transmitted line.
            var chan: [SSTVChannel: [Double]] = [:]
            var offMs = 0.0
            for seg in mode.line {
                if seg.channel == .sync || seg.channel == .gap { offMs += seg.ms; continue }
                var row = [Double](repeating: 0, count: w)
                for px in 0..<w { row[px] = sampleValue(lineStart: lineStart, segOffsetMs: offMs, segMs: seg.ms, px: px) }
                chan[seg.channel] = row
                offMs += seg.ms
            }
            writeLine(&rgb, w: w, h: h, transmittedLine: tl, mode: mode, chan: chan)
        }
        return imageFromRGBA(rgb, width: w, height: h)
    }

    private nonisolated static func writeLine(_ rgb: inout [UInt8], w: Int, h: Int, transmittedLine tl: Int,
                                              mode: SSTVMode, chan: [SSTVChannel: [Double]]) {
        func put(_ y: Int, _ x: Int, _ r: Double, _ g: Double, _ b: Double) {
            guard y >= 0, y < h, x >= 0, x < w else { return }
            let o = (y * w + x) * 4
            rgb[o] = UInt8(max(0, min(255, r * 255)))
            rgb[o+1] = UInt8(max(0, min(255, g * 255)))
            rgb[o+2] = UInt8(max(0, min(255, b * 255)))
            rgb[o+3] = 255
        }
        switch mode.colorSpace {
        case .rgb:
            let r = chan[.r], g = chan[.g], b = chan[.b]
            let y = tl
            for x in 0..<w { put(y, x, r?[x] ?? 0, g?[x] ?? 0, b?[x] ?? 0) }
        case .ycbcr:
            let cb = chan[.cb], cr = chan[.cr]
            if mode.linesPerScan == 2 {
                let y0 = chan[.y0], y1 = chan[.y1]
                for x in 0..<w {
                    let (r0, g0, b0) = ycbcr(y0?[x] ?? 0, cb?[x] ?? 0.5, cr?[x] ?? 0.5)
                    put(tl * 2, x, r0, g0, b0)
                    let (r1, g1, b1) = ycbcr(y1?[x] ?? 0, cb?[x] ?? 0.5, cr?[x] ?? 0.5)
                    put(tl * 2 + 1, x, r1, g1, b1)
                }
            } else {
                let y0 = chan[.y0]
                for x in 0..<w {
                    let (r, g, b) = ycbcr(y0?[x] ?? 0, cb?[x] ?? 0.5, cr?[x] ?? 0.5)
                    put(tl, x, r, g, b)
                }
            }
        }
    }

    private nonisolated static func ycbcr(_ y: Double, _ cb: Double, _ cr: Double) -> (Double, Double, Double) {
        // Inputs 0…1; Cb/Cr centered at 0.5.
        let Y = y * 255.0, Cb = cb * 255.0 - 128.0, Cr = cr * 255.0 - 128.0
        let r = (Y + 1.402 * Cr) / 255.0
        let g = (Y - 0.344136 * Cb - 0.714136 * Cr) / 255.0
        let b = (Y + 1.772 * Cb) / 255.0
        return (r, g, b)
    }

    private nonisolated static func imageFromRGBA(_ bytes: [UInt8], width: Int, height: Int) -> UIImage? {
        guard width > 0, height > 0 else { return nil }
        var data = bytes
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: cs, bitmapInfo: info),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }
}
