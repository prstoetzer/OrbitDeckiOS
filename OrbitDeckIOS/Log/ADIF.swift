import Foundation

// ===========================================================================
//  ADIF.swift — ADIF 3.1.7 import/export for the QSO log
//
//  Field mapping ported from CardSat (exportAdif in app.cpp): satellite QSOs use
//  PROP_MODE=SAT, uplink → FREQ/BAND, downlink → FREQ_RX/BAND_RX, and multiple
//  worked grids → VUCC_GRIDS. General export uses the compact ADIF date/time
//  (YYYYMMDD / HHMMSS); the LoTW .tq8 builds its own text-date records separately.
// ===========================================================================

enum ADIF {

    /// ADIF/LoTW band label for a frequency in MHz (uppercase, per LoTW examples).
    static func band(mhz: Double) -> String {
        switch mhz {
        case 28...29.7:     return "10M"
        case 50...54:       return "6M"
        case 144...148:     return "2M"
        case 222...225:     return "1.25M"
        case 420...450:     return "70CM"
        case 902...928:     return "33CM"
        case 1240...1300:   return "23CM"
        case 2300...2450:   return "13CM"
        case 3300...3500:   return "9CM"
        case 5650...5925:   return "6CM"
        case 10000...10500: return "3CM"
        default:            return ""
        }
    }

    // MARK: Export

    static func export(_ records: [QSORecord]) -> String {
        var out = "OrbitDeck ADIF export\n"
        out += field("ADIF_VER", "3.1.7")
        out += field("PROGRAMID", "OrbitDeck")
        out += "<EOH>\n"
        for q in records { out += record(q) }
        return out
    }

    private static func record(_ q: QSORecord) -> String {
        let (date, time) = compactDateTime(q.utc)
        let dlM = Double(q.dlHz) / 1e6, ulM = Double(q.ulHz) / 1e6
        var r = ""
        r += field("CALL", q.call)
        r += field("QSO_DATE", date)
        r += field("TIME_ON", time)
        // FT4/JS8 are SUBMODEs of MFSK in ADIF (FT8 is its own MODE). Emitting a bare
        // MODE=FT4 is invalid ADIF and mis-imports into Cloudlog/Wavelog.
        let (adifMode, adifSub) = Self.adifMode(q.mode)
        r += field("MODE", adifMode)
        if let adifSub { r += field("SUBMODE", adifSub) }
        if !q.sat.isEmpty { r += field("SAT_NAME", LoTWSatName.resolve(q.sat)) }
        r += field("PROP_MODE", "SAT")
        if ulM > 0 { r += field("FREQ", String(format: "%.4f", ulM)); r += field("BAND", band(mhz: ulM)) }
        if dlM > 0 { r += field("FREQ_RX", String(format: "%.4f", dlM)); r += field("BAND_RX", band(mhz: dlM)) }
        if !q.rstSent.isEmpty { r += field("RST_SENT", q.rstSent) }
        if !q.rstRcvd.isEmpty { r += field("RST_RCVD", q.rstRcvd) }
        let grids = q.gridList
        if let first = grids.first { r += field("GRIDSQUARE", first) }
        if grids.count > 1 { r += field("VUCC_GRIDS", grids.joined(separator: ",")) }
        if !q.myGrid.isEmpty { r += field("MY_GRIDSQUARE", q.myGrid) }
        if !q.myCall.isEmpty { r += field("STATION_CALLSIGN", q.myCall) }
        if !q.notes.isEmpty { r += field("COMMENT", q.notes) }
        r += "<EOR>\n"
        return r
    }

    /// Canonical ADIF (MODE, SUBMODE?) for a stored mode string. FT4 and JS8 are
    /// SUBMODEs of MFSK; FT8 is a top-level MODE; everything else passes through.
    static func adifMode(_ mode: String) -> (String, String?) {
        switch mode.uppercased() {
        case "FT4": return ("MFSK", "FT4")
        case "JS8": return ("MFSK", "JS8")
        default:    return (mode, nil)
        }
    }

    /// `<NAME:len>value` — the ADIF field primitive (length is byte count).
    static func field(_ name: String, _ value: String) -> String {
        guard !value.isEmpty else { return "" }
        return "<\(name):\(value.utf8.count)>\(value) "
    }

    private static func compactDateTime(_ date: Date) -> (String, String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let d = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let t = String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return (d, t)
    }

    // MARK: Import

    /// Parse an ADIF document into QSO records (best-effort; unknown fields ignored).
    static func parse(_ text: String) -> [QSORecord] {
        // Skip the header (everything up to and including <EOH>).
        let lower = text.lowercased()
        var scan = text.startIndex
        if let eoh = lower.range(of: "<eoh>") { scan = eoh.upperBound }

        var records: [QSORecord] = []
        var fields: [String: String] = [:]
        let chars = Array(text)
        var i = text.distance(from: text.startIndex, to: scan)
        let n = chars.count

        func flush() {
            guard !fields.isEmpty else { return }
            records.append(recordFrom(fields))
            fields.removeAll()
        }

        while i < n {
            guard chars[i] == "<" else { i += 1; continue }
            guard let close = nextIndex(of: ">", in: chars, from: i + 1) else { break }
            let tag = String(chars[(i + 1)..<close]).lowercased()
            if tag == "eor" { flush(); i = close + 1; continue }
            if tag == "eoh" { i = close + 1; continue }
            let parts = tag.split(separator: ":")
            guard parts.count >= 2, let len = Int(parts[1]) else { i = close + 1; continue }
            let valStart = close + 1
            let valEnd = min(n, valStart + len)
            let value = String(chars[valStart..<valEnd])
            fields[String(parts[0])] = value
            i = valEnd
        }
        flush()
        return records
    }

    private static func nextIndex(of ch: Character, in chars: [Character], from: Int) -> Int? {
        var j = from
        while j < chars.count { if chars[j] == ch { return j }; j += 1 }
        return nil
    }

    private static func recordFrom(_ f: [String: String]) -> QSORecord {
        var q = QSORecord(utc: parseDateTime(date: f["qso_date"], time: f["time_on"]))
        q.call = f["call"] ?? ""
        // Collapse MFSK + SUBMODE (FT4/JS8) back to the stored standalone mode.
        let m = (f["mode"] ?? "SSB").uppercased()
        let sub = (f["submode"] ?? "").uppercased()
        q.mode = (m == "MFSK" && !sub.isEmpty) ? sub : m
        q.sat = f["sat_name"] ?? ""
        if let fr = f["freq"], let m = Double(fr) { q.ulHz = Int64((m * 1e6).rounded()) }
        if let fr = f["freq_rx"], let m = Double(fr) { q.dlHz = Int64((m * 1e6).rounded()) }
        q.rstSent = f["rst_sent"] ?? ""
        q.rstRcvd = f["rst_rcvd"] ?? ""
        q.grid = f["vucc_grids"] ?? f["gridsquare"] ?? ""
        q.myGrid = f["my_gridsquare"] ?? ""
        q.myCall = f["station_callsign"] ?? ""
        q.notes = f["comment"] ?? ""
        return q
    }

    private static func parseDateTime(date: String?, time: String?) -> Date {
        guard let d = date, d.count >= 8 else { return Date() }
        let t = (time ?? "000000").padding(toLength: 6, withPad: "0", startingAt: 0)
        var c = DateComponents()
        c.year = Int(d.prefix(4)); c.month = Int(d.dropFirst(4).prefix(2)); c.day = Int(d.dropFirst(6).prefix(2))
        c.hour = Int(t.prefix(2)); c.minute = Int(t.dropFirst(2).prefix(2)); c.second = Int(t.dropFirst(4).prefix(2))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c) ?? Date()
    }
}
