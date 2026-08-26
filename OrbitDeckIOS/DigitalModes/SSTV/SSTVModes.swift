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

/// A scan channel within a line, or a non-image interval.
enum SSTVChannel { case r, g, b, y0, y1, cb, cr, sync, gap }

struct SSTVSegment {
    let channel: SSTVChannel
    let ms: Double
}

struct SSTVMode {
    let name: String
    let vis: Int
    let width: Int
    let height: Int
    let colorSpace: SSTVColorSpace
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
        return SSTVMode(name: name, vis: vis, width: 320, height: 256, colorSpace: .rgb, linesPerScan: 1, line: [
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
        return SSTVMode(name: name, vis: vis, width: 320, height: 256, colorSpace: .rgb, linesPerScan: 1, line: [
            .init(channel: .sync, ms: 9.0), .init(channel: .gap, ms: 1.5),
            .init(channel: .g, ms: scan), .init(channel: .gap, ms: 1.5),
            .init(channel: .b, ms: scan), .init(channel: .gap, ms: 1.5),
            .init(channel: .r, ms: scan), .init(channel: .gap, ms: 1.5)
        ])
    }

    static let robot36 = SSTVMode(name: "Robot 36", vis: 0x08, width: 320, height: 240, colorSpace: .ycbcr, linesPerScan: 1, line: [
        .init(channel: .sync, ms: 9.0), .init(channel: .gap, ms: 3.0),
        .init(channel: .y0, ms: 88.0), .init(channel: .gap, ms: 4.5),
        .init(channel: .cb, ms: 44.0)   // Robot 36 alternates Cr/Cb per line; approximated as one chroma
    ])
    static let robot72 = SSTVMode(name: "Robot 72", vis: 0x0C, width: 320, height: 240, colorSpace: .ycbcr, linesPerScan: 1, line: [
        .init(channel: .sync, ms: 9.0), .init(channel: .gap, ms: 3.0),
        .init(channel: .y0, ms: 138.0), .init(channel: .gap, ms: 4.5),
        .init(channel: .cb, ms: 69.0), .init(channel: .gap, ms: 4.5),
        .init(channel: .cr, ms: 69.0)
    ])
    static let wraaseSC2_180 = SSTVMode(name: "Wraase SC2-180", vis: 0x37, width: 320, height: 256, colorSpace: .rgb, linesPerScan: 1, line: [
        .init(channel: .sync, ms: 5.5225), .init(channel: .gap, ms: 0.5),
        .init(channel: .r, ms: 235.0), .init(channel: .g, ms: 235.0), .init(channel: .b, ms: 235.0)
    ])
    /// PD modes pack two image lines per transmitted line: Y(line0), Cr, Cb, Y(line1).
    static func pd(_ name: String, vis: Int, height: Int, scanMs: Double) -> SSTVMode {
        SSTVMode(name: name, vis: vis, width: 320, height: height, colorSpace: .ycbcr, linesPerScan: 2, line: [
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
        pd("PD 90", vis: 0x63, height: 256, scanMs: 170.240 / 2),
        pd("PD 120", vis: 0x5F, height: 496, scanMs: 121.600 / 2),
        pd("PD 180", vis: 0x60, height: 496, scanMs: 183.040 / 2)
    ]

    static func mode(forVIS vis: Int) -> SSTVMode? { all.first { $0.vis == vis } }
}
