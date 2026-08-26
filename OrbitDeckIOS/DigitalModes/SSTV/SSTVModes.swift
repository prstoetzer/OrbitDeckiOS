import Foundation

// ===========================================================================
//  SSTVModes.swift — SSTV mode timing tables
//
//  Each mode is described as a color space plus a per-line sequence of timed
//  segments (sync, porch/separator, and one scan per color channel). The decoder
//  walks these segments generically, so adding a mode is data, not code. Timing
//  constants are the standard published values; real-world decoding still needs
//  on-air calibration (slant/tuning), so these are a faithful starting point.
// ===========================================================================

enum SSTVColorSpace { case rgb, ycbcr }

/// How a transmitted line maps to output image rows.
///  - `perLine`: one transmitted line = one image row (RGB or full YCbCr).
///  - `pdDouble`: one transmitted line carries two image rows (PD: Y0, Cr, Cb, Y1).
///  - `robot36`: one transmitted line = one image row, but chroma alternates
///     R-Y (even lines) / B-Y (odd lines) and is shared with the neighbor row.
enum SSTVPacking { case perLine, pdDouble, robot36 }

/// A scan channel within a line, or a non-image interval.
enum SSTVChannel { case r, g, b, y0, y1, cb, cr, sync, gap }

struct SSTVSegment {
    let channel: SSTVChannel
    let ms: Double
}

struct SSTVMode: Identifiable, Hashable {
    var id: String { name }
    static func == (a: SSTVMode, b: SSTVMode) -> Bool { a.name == b.name }
    func hash(into h: inout Hasher) { h.combine(name) }

    let name: String
    let vis: Int
    let width: Int
    let height: Int
    let colorSpace: SSTVColorSpace
    let packing: SSTVPacking
    /// Image lines produced per transmitted line (PD packs 2).
    let linesPerScan: Int
    /// The full transmitted-line structure, in order.
    let line: [SSTVSegment]

    var lineMs: Double { line.reduce(0) { $0 + $1.ms } }
}

enum SSTVModes {
    // Common scan/sync/porch constants (ms).
    private static func martin(_ name: String, vis: Int, pixel: Double) -> SSTVMode {
        let scan = pixel * 320
        return SSTVMode(name: name, vis: vis, width: 320, height: 256, colorSpace: .rgb, packing: .perLine, linesPerScan: 1, line: [
            .init(channel: .sync, ms: 4.862), .init(channel: .gap, ms: 0.572),
            .init(channel: .g, ms: scan), .init(channel: .gap, ms: 0.572),
            .init(channel: .b, ms: scan), .init(channel: .gap, ms: 0.572),
            .init(channel: .r, ms: scan), .init(channel: .gap, ms: 0.572)
        ])
    }
    private static func scottie(_ name: String, vis: Int, pixel: Double) -> SSTVMode {
        let scan = pixel * 320
        // Simplified line-start-at-sync model (Scottie's sync sits between B and R;
        // decoders re-align on the sync each line).
        return SSTVMode(name: name, vis: vis, width: 320, height: 256, colorSpace: .rgb, packing: .perLine, linesPerScan: 1, line: [
            .init(channel: .sync, ms: 9.0), .init(channel: .gap, ms: 1.5),
            .init(channel: .g, ms: scan), .init(channel: .gap, ms: 1.5),
            .init(channel: .b, ms: scan), .init(channel: .gap, ms: 1.5),
            .init(channel: .r, ms: scan), .init(channel: .gap, ms: 1.5)
        ])
    }

    // Robot 36: full-resolution Y every line + ONE chroma component per line,
    // alternating R-Y (even lines) and B-Y (odd lines). Line = 150 ms.
    static let robot36 = SSTVMode(name: "Robot 36", vis: 0x08, width: 320, height: 240, colorSpace: .ycbcr, packing: .robot36, linesPerScan: 1, line: [
        .init(channel: .sync, ms: 9.0), .init(channel: .gap, ms: 3.0),
        .init(channel: .y0, ms: 88.0), .init(channel: .gap, ms: 6.0),
        .init(channel: .cb, ms: 44.0)   // chroma slot; R-Y or B-Y depending on line parity
    ])
    // Robot 72: full 4:2:2 YCbCr per line — Y, R-Y (Cr), B-Y (Cb). Line = 300 ms.
    static let robot72 = SSTVMode(name: "Robot 72", vis: 0x0C, width: 320, height: 240, colorSpace: .ycbcr, packing: .perLine, linesPerScan: 1, line: [
        .init(channel: .sync, ms: 9.0), .init(channel: .gap, ms: 3.0),
        .init(channel: .y0, ms: 138.0), .init(channel: .gap, ms: 4.5),
        .init(channel: .cr, ms: 69.0), .init(channel: .gap, ms: 4.5),
        .init(channel: .cb, ms: 69.0), .init(channel: .gap, ms: 3.0)
    ])
    static let wraaseSC2_180 = SSTVMode(name: "Wraase SC2-180", vis: 0x37, width: 320, height: 256, colorSpace: .rgb, packing: .perLine, linesPerScan: 1, line: [
        .init(channel: .sync, ms: 5.5225), .init(channel: .gap, ms: 0.5),
        .init(channel: .r, ms: 235.0), .init(channel: .g, ms: 235.0), .init(channel: .b, ms: 235.0)
    ])
    /// PD modes pack two image lines per transmitted line: Y(line0), Cr, Cb, Y(line1).
    /// `scanMs` is the full per-channel scan time; `width`/`height` vary by mode.
    static func pd(_ name: String, vis: Int, width: Int, height: Int, scanMs: Double) -> SSTVMode {
        SSTVMode(name: name, vis: vis, width: width, height: height, colorSpace: .ycbcr, packing: .pdDouble, linesPerScan: 2, line: [
            .init(channel: .sync, ms: 20.0), .init(channel: .gap, ms: 2.08),
            .init(channel: .y0, ms: scanMs), .init(channel: .cr, ms: scanMs),
            .init(channel: .cb, ms: scanMs), .init(channel: .y1, ms: scanMs)
        ])
    }

    static let all: [SSTVMode] = [
        martin("Martin M1", vis: 0x2C, pixel: 0.4576),
        martin("Martin M2", vis: 0x28, pixel: 0.2288),
        scottie("Scottie S1", vis: 0x3C, pixel: 0.4320),
        scottie("Scottie S2", vis: 0x38, pixel: 0.2752),
        scottie("Scottie DX", vis: 0x4C, pixel: 1.0800),
        robot36, robot72, wraaseSC2_180,
        pd("PD 50",  vis: 0x5D, width: 320, height: 256, scanMs: 91.520),
        pd("PD 90",  vis: 0x63, width: 320, height: 256, scanMs: 170.240),
        pd("PD 120", vis: 0x5F, width: 640, height: 496, scanMs: 121.600),
        pd("PD 160", vis: 0x62, width: 512, height: 400, scanMs: 195.584),
        pd("PD 180", vis: 0x60, width: 640, height: 496, scanMs: 183.040),
        pd("PD 240", vis: 0x61, width: 640, height: 496, scanMs: 244.480),
        pd("PD 290", vis: 0x5E, width: 800, height: 616, scanMs: 228.800)
    ]

    static func mode(forVIS vis: Int) -> SSTVMode? { all.first { $0.vis == vis } }
}
