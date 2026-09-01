import Foundation

// ===========================================================================
//  RotatorCodec.swift — byte-exact rotator command builders + position parsers
//
//  Pure, stateless. Ported from CardSat's rotator.cpp. Azimuth/elevation come in
//  already offset/flipped/normalized by the controller; each protocol applies its
//  own final clamp exactly as CardSat does.
// ===========================================================================

enum RotatorCodec {

    /// Build the "point to az/el" command for a protocol.
    static func point(_ proto: RotatorProtocolKind, az: Double, el: Double) -> [UInt8] {
        switch proto {
        case .gs232:
            var a = az; if a < 0 { a += 360 }; if a > 450 { a = 450 }
            var e = el; if e < 0 { e = 0 }; if e > 180 { e = 180 }
            return ascii(String(format: "W%03d %03d\r", Int(a.rounded()), Int(e.rounded())))
        case .easycomm1:
            let (a, e) = ecClamp(az, el)
            return ascii(String(format: "AZ%d EL%d\r", Int(a.rounded()), Int(e.rounded())))
        case .easycomm2, .easycomm3:
            let (a, e) = ecClamp(az, el)
            return ascii(String(format: "AZ%.1f EL%.1f\r", a, e))
        case .spid:
            var a = az; if a < 0 { a += 360 }; if a > 360 { a -= 360 }
            var e = el; if e < 0 { e = 0 }; if e > 180 { e = 180 }
            return spidFrame(cmd: 0x2F, az: a, el: e)
        case .saebrtrack:
            // Compact whole-degree "AZnnnELnnn", LF-terminated (Arduino/SatPC32 style).
            var a = az; if a < 0 { a += 360 }; if a > 360 { a -= 360 }
            var e = el; if e < 0 { e = 0 }; if e > 180 { e = 180 }
            return ascii(String(format: "AZ%03dEL%03d\n", Int(a.rounded()), Int(e.rounded())))
        case .urc:
            // OZ9AAR URC TCP/JSON GOTO (degrees, up to 1 dp).
            var a = az; if a < 0 { a += 360 }
            var e = el; if e < 0 { e = 0 }
            return ascii(String(format: "{\"GOTO\":[%.1f,%.1f]}", a, e))
        case .rotctld:
            var e = el; if e < 0 { e = 0 }
            return ascii(String(format: "P %.1f %.1f\n", az, e))
        case .pstRotator:
            var a = az; if a < 0 { a += 360 }
            var e = el; if e < 0 { e = 0 }
            // PstRotator's documented "send both az+el for tracking" UDP command
            // (Communication ▸ UDP Control Port). Az and el are space-separated
            // inside a single <TRACK> tag.
            return ascii(String(format: "<PST><TRACK>%.1f %.1f</TRACK></PST>", a, e))
        }
    }

    /// The frame(s) to command a position. One datagram/frame for every protocol,
    /// matching CardSat exactly (PstRotator uses the combined
    /// `<PST><AZIMUTH>…</AZIMUTH><ELEVATION>…</ELEVATION></PST>` datagram).
    static func pointDatagrams(_ proto: RotatorProtocolKind, az: Double, el: Double) -> [[UInt8]] {
        [point(proto, az: az, el: el)]
    }

    /// Stop / all-stop command.
    static func stop(_ proto: RotatorProtocolKind) -> [UInt8] {
        switch proto {
        case .gs232: ascii("S\r")
        case .easycomm1, .easycomm2, .easycomm3: ascii("SA SE\r")
        case .spid: spidFrame(cmd: 0x0F, az: 0, el: 0)
        case .saebrtrack: []            // no stop command (fire-and-forget); AZ/EL would goto 0
        case .rotctld: ascii("S\n")
        case .pstRotator: ascii("<PST><STOP>1</STOP></PST>")
        case .urc: []                   // URC has no stop request (POLL/GOTO only)
        }
    }

    /// Position-query command, or nil if the protocol has none we use.
    static func positionQuery(_ proto: RotatorProtocolKind) -> [UInt8]? {
        switch proto {
        case .gs232: ascii("C2\r")
        case .easycomm1, .easycomm2, .easycomm3: ascii("AZ EL\r")
        case .spid: spidFrame(cmd: 0x1F, az: 0, el: 0)
        case .saebrtrack: nil            // fire-and-forget; a bare AZ/EL query is misread as goto-0
        case .rotctld: ascii("p\n")
        case .pstRotator: nil            // reply comes on port+1; not used by the loop
        case .urc: ascii("{\"POLL\"}")
        }
    }

    /// Parse a position reply into (azimuth, elevation) degrees, if present.
    static func parsePosition(_ proto: RotatorProtocolKind, _ bytes: [UInt8]) -> (az: Double, el: Double)? {
        switch proto {
        case .spid:
            // 12-byte reply: 0x57, az[4], PH, el[4], PV, 0x20.
            guard let i = bytes.firstIndex(of: 0x57), bytes.count >= i + 12, bytes[i + 11] == 0x20 else { return nil }
            let res = max(1, Int(bytes[i + 5]))
            let az = Double(Int(bytes[i+1]) * 1000 + Int(bytes[i+2]) * 100 + Int(bytes[i+3]) * 10 + Int(bytes[i+4])) / Double(res) - 360
            let el = Double(Int(bytes[i+6]) * 1000 + Int(bytes[i+7]) * 100 + Int(bytes[i+8]) * 10 + Int(bytes[i+9])) / Double(res) - 360
            return (az, el)
        default:
            guard let s = String(bytes: bytes, encoding: .ascii) else { return nil }
            return parseText(proto, s)
        }
    }

    // MARK: text parsing

    private static func parseText(_ proto: RotatorProtocolKind, _ s: String) -> (az: Double, el: Double)? {
        switch proto {
        case .gs232:
            if let r = s.range(of: "AZ=") {           // GS-232B: "AZ=aaaEL=eee"
                let az = leadingNumber(after: r.upperBound, in: s)
                if let er = s.range(of: "EL=") {
                    let el = leadingNumber(after: er.upperBound, in: s)
                    if let az, let el { return (az, el) }
                }
            }
            if let r = s.firstIndex(of: "+") {         // GS-232A: "+0aaa+0eee"
                let rest = s[r...]
                let nums = rest.split(whereSeparator: { $0 == "+" }).compactMap { Double($0.filter { $0.isNumber }) }
                if nums.count >= 2 { return (nums[0], nums[1]) }
            }
            return nil
        case .easycomm1, .easycomm2, .easycomm3:
            guard let ar = s.range(of: "AZ"), let er = s.range(of: "EL") else { return nil }
            let az = leadingNumber(after: ar.upperBound, in: s)
            let el = leadingNumber(after: er.upperBound, in: s)
            if let az, let el { return (az, el) }
            return nil
        case .rotctld:
            // "<az>\n<el>\n"; error is "RPRT -n".
            if s.contains("RPRT") && !s.hasPrefix("RPRT 0") { return nil }
            let lines = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if lines.count >= 2 { return (lines[0], lines[1]) }
            return nil
        case .pstRotator:
            guard let ar = s.range(of: "AZ:"), let er = s.range(of: "EL:") else { return nil }
            let az = leadingNumber(after: ar.upperBound, in: s)
            let el = leadingNumber(after: er.upperBound, in: s)
            if let az, let el { return (az, el) }
            return nil
        case .saebrtrack:
            // "AZnnnELnnn" (or spaced). Split on EL; read the leading number of each part.
            guard let ar = s.range(of: "AZ"), let er = s.range(of: "EL") else { return nil }
            let az = Double(s[ar.upperBound..<er.lowerBound].filter { $0.isNumber || $0 == "." || $0 == "-" })
            let el = leadingNumber(after: er.upperBound, in: s)
            if let az, let el { return (az, el) }
            return nil
        case .urc:
            // JSON status {"AZ":123.4,"EL":45.6}: find each key, read the number after its colon.
            func jsonNum(_ key: String) -> Double? {
                guard let kr = s.range(of: key) else { return nil }
                guard let colon = s[kr.upperBound...].firstIndex(of: ":") else { return nil }
                return leadingNumber(after: s.index(after: colon), in: s)
            }
            if let az = jsonNum("\"AZ\"") ?? jsonNum("\"az\""),
               let el = jsonNum("\"EL\"") ?? jsonNum("\"el\"") { return (az, el) }
            return nil
        case .spid: return nil
        }
    }

    /// Parse a signed decimal number at the start of the substring following `idx`.
    private static func leadingNumber(after idx: String.Index, in s: String) -> Double? {
        var out = ""
        for c in s[idx...] {
            if c.isNumber || c == "." || c == "-" || c == "+" { out.append(c) }
            else if !out.isEmpty { break }
            else if c == " " { continue }
            else { break }
        }
        return Double(out)
    }

    // MARK: helpers

    private static func ecClamp(_ az: Double, _ el: Double) -> (Double, Double) {
        var a = az; if a < 0 { a += 360 }; if a > 360 { a -= 360 }
        var e = el; if e < 0 { e = 0 }; if e > 180 { e = 180 }
        return (a, e)
    }

    /// SPID Rot2Prog 13-byte frame. RES = 1 (whole-degree). cmd: 0x2F set,
    /// 0x1F status, 0x0F stop.
    private static func spidFrame(cmd: UInt8, az: Double, el: Double) -> [UInt8] {
        let res = 1
        func digits(_ deg: Double) -> [UInt8] {
            let v = Int(((deg + 360) * Double(res)).rounded())
            return [UInt8((v / 1000) % 10), UInt8((v / 100) % 10), UInt8((v / 10) % 10), UInt8(v % 10)]
        }
        let a = (cmd == 0x2F) ? digits(az) : [0, 0, 0, 0]
        let e = (cmd == 0x2F) ? digits(el) : [0, 0, 0, 0]
        return [0x57] + a + [UInt8(res)] + e + [UInt8(res), cmd, 0x20]
    }

    private static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }
}
