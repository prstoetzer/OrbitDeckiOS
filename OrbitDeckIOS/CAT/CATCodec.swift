import Foundation

// ===========================================================================
//  CATCodec.swift — byte-level CAT frame encoders/decoders
//
//  Pure, stateless builders ported from CardSat (civ.cpp, yaesu.cpp,
//  kenwood.cpp, rig.cpp leg builders). Every function returns the exact bytes
//  a radio expects, so they can be unit-tested without hardware.
//
//  Frequencies are Hz. CI-V frames are "FE FE <to> <from> … FD" with the host
//  address 0xE0; the same frames go over a BLE UART adapter or wrapped in an
//  RS-BA1 serial packet — only the transport differs.
// ===========================================================================

/// Which VFO a Yaesu FT-847 frame targets. Mono radios use `.plain`.
enum YaesuVFO { case plain, satRX, satTX }

enum CATCodec {
    static let host: UInt8 = 0xE0

    // MARK: CI-V (Icom)

    /// Little-endian BCD, two digits per byte.
    static func civBCD(_ hz: UInt64, bytes: Int) -> [UInt8] {
        var v = hz
        var out = [UInt8](repeating: 0, count: bytes)
        for i in 0..<bytes {
            let lo = UInt8(v % 10); v /= 10
            let hi = UInt8(v % 10); v /= 10
            out[i] = (hi << 4) | lo
        }
        return out
    }

    static func civFrame(addr: UInt8, payload: [UInt8]) -> [UInt8] {
        [0xFE, 0xFE, addr, host] + payload + [0xFD]
    }

    static func civSetFreq(_ spec: RadioSpec, addr: UInt8, hz: UInt64) -> [UInt8] {
        let n = (spec.wideFreq && hz > 5_850_000_000) ? 6 : 5
        return civFrame(addr: addr, payload: [0x05] + civBCD(hz, bytes: n))
    }

    static func civModeByte(_ m: RigMode) -> UInt8 {
        switch m { case .lsb: 0x00; case .usb: 0x01; case .am: 0x02; case .cw: 0x03; case .fm: 0x05; case .data: 0x01 }
    }

    static func civSetMode(_ spec: RadioSpec, addr: UInt8, mode: RigMode) -> [UInt8] {
        if spec.modeFilter {
            return civFrame(addr: addr, payload: [0x06, civModeByte(mode), 0x01])
        }
        return civFrame(addr: addr, payload: [0x06, civModeByte(mode)])
    }

    /// MAIN/SUB band-access select (full-duplex Icom only); nil if not applicable.
    static func civSelect(_ spec: RadioSpec, addr: UInt8, sub: Bool) -> [UInt8]? {
        let sel = sub ? spec.selSub : spec.selMain
        guard !sel.isEmpty else { return nil }
        return civFrame(addr: addr, payload: sel)
    }

    static func civSatMode(_ spec: RadioSpec, addr: UInt8, on: Bool) -> [UInt8]? {
        guard spec.hasSatMode, spec.satModeCmd != 0 else { return nil }
        return civFrame(addr: addr, payload: [spec.satModeCmd, spec.satModeSub, on ? 0x01 : 0x00])
    }

    /// CTCSS frames for the uplink: [tone-frequency set, encoder on] or [encoder off].
    static func civTone(_ spec: RadioSpec, addr: UInt8, on: Bool, toneHz: Double) -> [[UInt8]] {
        guard spec.hasTone else { return [] }
        if on, toneHz > 0 {
            let t = Int((toneHz * 10).rounded())            // tenths of Hz
            let b1 = UInt8((((t / 1000) % 10) << 4) | ((t / 100) % 10))
            let b2 = UInt8((((t / 10) % 10) << 4) | (t % 10))
            return [civFrame(addr: addr, payload: [0x1B, 0x00, b1, b2]),
                    civFrame(addr: addr, payload: [0x16, spec.toneEncSub, 0x01])]
        }
        return [civFrame(addr: addr, payload: [0x16, spec.toneEncSub, 0x00])]
    }

    /// CI-V band code for the "07 D2" assignment (2 m / 70 cm / 23 cm), or 0.
    static func civBandCode(_ hz: UInt64) -> UInt8 {
        if (144_000_000...148_000_000).contains(hz) { return 0x01 }
        if (430_000_000...450_000_000).contains(hz) { return 0x02 }
        if (1_240_000_000...1_300_000_000).contains(hz) { return 0x03 }
        return 0x00
    }

    /// 07 D2 band-assignment frames (IC-9100/9700). Empty if unavailable/unknown.
    static func civAssignBands(_ spec: RadioSpec, addr: UInt8, mainHz: UInt64, subHz: UInt64) -> [[UInt8]] {
        guard spec.canAssignBand else { return [] }
        let mb = civBandCode(mainHz), sb = civBandCode(subHz)
        guard mb != 0, sb != 0 else { return [] }
        return [civFrame(addr: addr, payload: [0x07, 0xD2, 0x00, mb]),
                civFrame(addr: addr, payload: [0x07, 0xD2, 0x01, sb])]
    }

    static func civReadFreq(addr: UInt8) -> [UInt8] { civFrame(addr: addr, payload: [0x03]) }

    /// Parse a CI-V read-frequency reply (FE FE E0 <addr> 03 <5/6 BCD> FD).
    static func civParseFreq(_ buf: [UInt8], addr: UInt8) -> UInt64? {
        var i = 0
        while i + 11 <= buf.count {
            if buf[i] == 0xFE, buf[i+1] == 0xFE, buf[i+2] == host, buf[i+3] == addr, buf[i+4] == 0x03 {
                if buf[i+10] == 0xFD { return unpackBCD(Array(buf[(i+5)...(i+9)])) }
                if i + 12 <= buf.count, buf[i+11] == 0xFD { return unpackBCD(Array(buf[(i+5)...(i+10)])) }
            }
            i += 1
        }
        return nil
    }

    private static func unpackBCD(_ b: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for byte in b.reversed() { v = v * 100 + UInt64(byte >> 4) * 10 + UInt64(byte & 0x0F) }
        return v
    }

    // MARK: Yaesu 5-byte binary (FT-817 family, FT-847, FT-100, VR-5000, FT-736R)

    /// Big-endian BCD, 10 Hz units, 4 bytes (FT-817/847/857/897/736/VR-5000).
    static func yaesuBCDBigEndian(_ hz: UInt64) -> [UInt8] {
        let f = (hz + 5) / 10
        func d(_ a: UInt64) -> UInt64 { a % 10 }
        return [
            UInt8((d(f/10_000_000) << 4) | d(f/1_000_000)),
            UInt8((d(f/100_000) << 4) | d(f/10_000)),
            UInt8((d(f/1_000) << 4) | d(f/100)),
            UInt8((d(f/10) << 4) | d(f)),
        ]
    }
    /// Little-endian BCD, 10 Hz units, 4 bytes (FT-100 only).
    static func yaesuBCDLittleEndian(_ hz: UInt64) -> [UInt8] {
        var f = (hz + 5) / 10
        var out = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { out[i] = UInt8((((f/10)%10) << 4) | (f%10)); f /= 100 }
        return out
    }

    static func yaesuBinModeByte(_ m: RigMode) -> UInt8 {
        switch m { case .lsb: 0x00; case .usb: 0x01; case .cw: 0x02; case .am: 0x04; case .fm: 0x08; case .data: 0x0A }
    }
    static func yaesuVR5000ModeByte(_ m: RigMode) -> UInt8 {
        switch m { case .lsb: 0x00; case .usb: 0x01; case .cw: 0x02; case .am: 0x04; case .fm: 0x88; case .data: 0x01 }
    }
    static func yaesuFT100ModeByte(_ m: RigMode) -> UInt8 {
        switch m { case .lsb: 0x00; case .usb: 0x01; case .cw: 0x02; case .am: 0x04; case .data: 0x05; case .fm: 0x06 }
    }

    /// Frequency frame. `vfo` selects the SAT VFO. FT-847 uses 0x11/0x21; the FT-736R
    /// uses main 0x01 (RX) / split 0x2E (TX) — see `ft736FullDuplexOn`. Mono rigs pass `.plain`.
    static func yaesuSetFreq(_ spec: RadioSpec, hz: UInt64, vfo: YaesuVFO) -> [UInt8] {
        if spec.family == .yaesuFT100 {
            return yaesuBCDLittleEndian(hz) + [0x0A]
        }
        if spec.family == .yaesuFT736 {
            // FT-736R full duplex (Hamlib ft736.c): RX = main (0x01), uplink = split TX (0x2E).
            let op: UInt8 = vfo == .satTX ? 0x2E : 0x01
            return yaesuBCDBigEndian(hz) + [op]
        }
        let op: UInt8 = vfo == .satRX ? 0x11 : vfo == .satTX ? 0x21 : 0x01
        return yaesuBCDBigEndian(hz) + [op]
    }

    static func yaesuSetMode(_ spec: RadioSpec, mode: RigMode, vfo: YaesuVFO) -> [UInt8] {
        switch spec.family {
        case .yaesuFT100:
            return [0, 0, 0, yaesuFT100ModeByte(mode), 0x0C]         // mode in data[3]
        case .yaesuVR5000:
            return [yaesuVR5000ModeByte(mode), 0, 0, 0, 0x07]
        case .yaesuFT736:
            // FT-736R: RX mode = 0x07, uplink (split TX) mode = 0x27 (Hamlib ft736.c).
            let op: UInt8 = vfo == .satTX ? 0x27 : 0x07
            return [yaesuBinModeByte(mode), 0, 0, 0, op]
        default:
            let op: UInt8 = vfo == .satRX ? 0x17 : vfo == .satTX ? 0x27 : 0x07
            return [yaesuBinModeByte(mode), 0, 0, 0, op]
        }
    }

    static func yaesuReadFreq(_ spec: RadioSpec, vfo: YaesuVFO) -> [UInt8] {
        switch spec.family {
        case .yaesuFT100: return [0, 0, 0, 0, 0x10]
        default:
            let op: UInt8 = vfo == .satRX ? 0x13 : 0x03
            return [0, 0, 0, 0, op]
        }
    }

    static let yaesuCATOn: [UInt8] = [0, 0, 0, 0, 0x00]
    /// FT-847 satellite mode ON (0x4E) / OFF (0x8E) — Hamlib ft847.c. The sat RX/TX VFO
    /// freq/mode commands (0x11/0x21, 0x17/0x27) can be set regardless of mode, but the
    /// radio must be in SAT for that tracking to drive actual receive/transmit. Harmless
    /// if the operator already pressed SAT.
    static let ft847SatModeOn: [UInt8] = [0, 0, 0, 0, 0x4E]
    static let ft847SatModeOff: [UInt8] = [0, 0, 0, 0, 0x8E]
    /// FT-736R full-duplex (split) ON (0x0E) / OFF (0x8E) — Hamlib ft736.c. Enabling it
    /// lets the RX (main) and uplink (split TX) VFOs be tuned independently for Doppler.
    static let ft736FullDuplexOn: [UInt8] = [0, 0, 0, 0, 0x0E]
    static let ft736FullDuplexOff: [UInt8] = [0, 0, 0, 0, 0x8E]

    /// FT-847 CTCSS CAT codes, in the shared 39-tone order.
    static let ft847CTCSS: [UInt8] = [
        0x3F,0x39,0x1F,0x3E,0x0F,0x3D,0x1E,0x3C,0x0E,0x3B,
        0x1D,0x3A,0x0D,0x1C,0x0C,0x1B,0x0B,0x1A,0x0A,0x19,
        0x09,0x18,0x08,0x17,0x07,0x16,0x06,0x15,0x05,0x14,
        0x04,0x13,0x03,0x12,0x02,0x11,0x01,0x10,0x00,
    ]

    /// FT-847 CTCSS frames for the SAT-TX (uplink) VFO: [tone, encoder-on] or [off].
    static func ft847Tone(on: Bool, toneHz: Double) -> [[UInt8]] {
        if !on || toneHz <= 0 { return [[0x8A, 0, 0, 0, 0x2A]] }
        guard let i = CTCSS.index(hz: toneHz) else { return [] }
        return [[ft847CTCSS[i], 0, 0, 0, 0x2B], [0x4A, 0, 0, 0, 0x2A]]
    }

    /// Parse a Yaesu 4-byte-BCD-+-mode read reply → Hz.
    static func yaesuParseFreq(_ spec: RadioSpec, _ buf: [UInt8]) -> UInt64? {
        if spec.family == .yaesuFT100 {
            guard buf.count >= 6 else { return nil }        // band_no, freq[4] (LE), mode
            var f: UInt64 = 0, mul: UInt64 = 1
            for i in 1...4 { f += (UInt64(buf[i] & 0x0F) + UInt64(buf[i] >> 4) * 10) * mul; mul *= 100 }
            let hz = f * 10; return hz > 0 ? hz : nil
        }
        guard buf.count >= 5 else { return nil }
        var f: UInt64 = 0
        for i in 0..<4 { f = f * 100 + UInt64(buf[i] >> 4) * 10 + UInt64(buf[i] & 0x0F) }
        let hz = f * 10; return hz > 0 ? hz : nil
    }

    // MARK: Kenwood base (TS-711/811/790/2000) — ASCII

    static func kwModeDigit(_ m: RigMode) -> Character {
        switch m { case .lsb: "1"; case .usb: "2"; case .cw: "3"; case .fm: "4"; case .am: "5"; case .data: "6" }
    }
    /// vfo = "FA" (VFO A / downlink) or "FB" (VFO B / uplink). 11 digits.
    static func kwSetFreq(vfo: String, hz: UInt64) -> [UInt8] {
        Array(String(format: "%@%011llu;", vfo, hz).utf8)
    }
    static func kwSetMode(_ m: RigMode) -> [UInt8] { Array("MD\(kwModeDigit(m));".utf8) }
    /// Read VFO A (downlink) or VFO B (uplink) on a full-duplex Kenwood.
    static func kwReadFreq(vfoB: Bool = false) -> [UInt8] { Array((vfoB ? "FB;" : "FA;").utf8) }
    /// TS-2000 TX CTCSS: TNnn (1-based) + TO1/TO0.
    static func kwTone(on: Bool, toneHz: Double) -> [[UInt8]] {
        if !on || toneHz <= 0 { return [Array("TO0;".utf8)] }
        guard let i = CTCSS.index(hz: toneHz) else { return [] }
        return [Array(String(format: "TN%02d;", i + 1).utf8), Array("TO1;".utf8)]
    }
    /// Parse "FA<digits>;" (or "FB…" for VFO B) → Hz. Base stations answer 11 digits.
    static func kwParseFreq(_ buf: [UInt8], digits: Int = 11, vfoB: Bool = false) -> UInt64? {
        guard let s = String(bytes: buf, encoding: .ascii), let r = s.range(of: vfoB ? "FB" : "FA") else { return nil }
        let start = s.index(r.upperBound, offsetBy: 0)
        let tail = s[start...].prefix(digits)
        guard tail.count == digits, tail.allSatisfy(\.isNumber) else { return nil }
        return UInt64(tail)
    }

    // MARK: Kenwood handheld (TH-D74/D75) — band B, ASCII, CR-terminated

    static let kwHandheldBand: Character = "1"   // band B

    static func khtModeDigit(_ m: RigMode) -> Character {
        switch m {
        case .fm, .data: "6"   // NFM (band B refuses plain FM/DV)
        case .am: "2"; case .lsb: "3"; case .usb: "4"; case .cw: "5"
        }
    }
    /// Single-frame set: "FQ b,<10 digits>\r" (must be on the radio's step grid).
    static func khtSetFreq(hz: UInt64) -> [UInt8] {
        Array(String(format: "FQ \(kwHandheldBand),%010llu\r", hz).utf8)
    }
    static func khtSetMode(_ m: RigMode) -> [UInt8] {
        Array("MD \(kwHandheldBand),\(khtModeDigit(m))\r".utf8)
    }
    static func khtReadFreq() -> [UInt8] { Array("FO \(kwHandheldBand)\r".utf8) }
    /// Session preconditions: VFO (not memory), then control band. Sent once.
    static func khtSession() -> [[UInt8]] {
        [Array("VM \(kwHandheldBand),0\r".utf8), Array("BC \(kwHandheldBand)\r".utf8)]
    }
    /// Fine-step frames for a mode: FT 1 + FS 0 (20 Hz) in SSB/CW/AM, else FT 0 (5 kHz).
    static func khtStep(for m: RigMode) -> [[UInt8]] {
        let fine = (m == .usb || m == .lsb || m == .cw || m == .am)
        var out: [[UInt8]] = [Array("FT \(fine ? "1" : "0")\r".utf8)]
        if fine { out.append(Array("FS 0\r".utf8)) }
        return out
    }
    /// Parse "FO b,<10-digit Hz>,…" → Hz (frequency at offset 5).
    static func khtParseFreq(_ buf: [UInt8]) -> UInt64? {
        guard let s = String(bytes: buf, encoding: .ascii), let r = s.range(of: "FO ") else { return nil }
        let after = s[r.upperBound...]                          // "b,<10 digits>,…"
        let parts = after.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let digits = parts[1].prefix(10)
        guard digits.count == 10, digits.allSatisfy(\.isNumber) else { return nil }
        return UInt64(digits)
    }

    // MARK: PTT (transmit keying) — used by full-duplex FT4

    /// CI-V PTT: 1C 00, 01 = TX, 00 = RX.
    static func civPTT(addr: UInt8, on: Bool) -> [UInt8] { [0xFE, 0xFE, addr, host, 0x1C, 0x00, on ? 0x01 : 0x00, 0xFD] }
    /// Yaesu 5-byte PTT (FT-817/847/857/897 family): 08 = ON, 88 = OFF.
    static func yaesuPTT(on: Bool) -> [UInt8] { [0, 0, 0, 0, on ? 0x08 : 0x88] }
    /// Kenwood ASCII PTT.
    static func kwPTT(on: Bool) -> [UInt8] { Array((on ? "TX;" : "RX;").utf8) }
    /// rigctld PTT (Hamlib NET): T 1 / T 0.
    static func rigctldSetPTT(on: Bool) -> [UInt8] { Array("T \(on ? 1 : 0)\n".utf8) }

    // MARK: rigctld (Hamlib NET rigctl)
    //
    // Long-form, newline-terminated ASCII commands to a `rigctld` server. Hamlib
    // owns the radio model, so these are model-agnostic. For a full-duplex single
    // radio we track downlink on the current VFO (`F`/`M`) and uplink on the split
    // VFO (`I`/`X`, with split enabled via `S 1 VFOB`). Replies to reads are the
    // value alone; errors are `RPRT <n>`.

    static func rigctldSetFreq(hz: UInt64) -> [UInt8] { Array("F \(hz)\n".utf8) }
    static func rigctldSetSplitFreq(hz: UInt64) -> [UInt8] { Array("I \(hz)\n".utf8) }
    static func rigctldSetMode(_ mode: RigMode) -> [UInt8] { Array("M \(hamlibMode(mode)) 0\n".utf8) }
    static func rigctldSetSplitMode(_ mode: RigMode) -> [UInt8] { Array("X \(hamlibMode(mode)) 0\n".utf8) }
    static func rigctldSetSplit(on: Bool) -> [UInt8] { Array("S \(on ? 1 : 0) VFOB\n".utf8) }
    static func rigctldReadFreq() -> [UInt8] { Array("f\n".utf8) }
    /// Read the split (TX) VFO frequency — for follow-uplink on a full-duplex split link.
    static func rigctldReadSplitFreq() -> [UInt8] { Array("i\n".utf8) }

    /// First numeric line of a rigctld reply (skips `RPRT` status lines).
    static func rigctldParseFreq(_ bytes: [UInt8]) -> UInt64? {
        guard let s = String(bytes: bytes, encoding: .ascii) else { return nil }
        for line in s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("RPRT") { continue }
            if let v = UInt64(t) { return v }
        }
        return nil
    }

    /// Hamlib mode token for a `RigMode`.
    private static func hamlibMode(_ m: RigMode) -> String {
        switch m {
        case .lsb: "LSB"; case .usb: "USB"; case .cw: "CW"
        case .fm: "FM"; case .am: "AM"; case .data: "PKTUSB"
        }
    }
}
