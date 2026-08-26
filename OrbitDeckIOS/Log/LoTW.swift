import Foundation
import Security

// ===========================================================================
//  LoTW.swift — on-device .tq8 signing + upload
//
//  The iOS-clean version of CardSat's lotw.cpp: sign the whole log in one pass
//  (no ESP32 batching/reboot/stored-gzip hacks). The user imports their LoTW
//  callsign certificate as a .p12 (from TQSL); we keep it in Application Support
//  (file-protected) and the passphrase in the Keychain, import the identity with
//  SecPKCS12Import, and sign each QSO with SecKeyCreateSignature (RSA PKCS#1 v1.5
//  over SHA-1 — LoTW-mandated). gzip is pure Swift (see Gzip).
//
//  The SIGNDATA normalization, TQSL internal field names, text date/time forms
//  and record order are ported byte-for-byte from CardSat's validated
//  implementation; any deviation makes LoTW silently drop the QSO.
// ===========================================================================

struct LoTWResult: Sendable {
    var ok = false
    var signed = 0
    var message = ""
}

/// Resolves a satellite's display name to a valid LoTW SAT_NAME (≤ 6 chars, LoTW's
/// own naming). Ported from CardSat: try the name itself, then each parenthesised
/// designator ("FOX-1B (AO-91)" → "AO-91"), against a built-in map of the
/// non-identity cases; otherwise prefer a parenthetical that already fits 6 chars,
/// else truncate. Keeps the .tq8 and the exported ADIF in agreement.
enum LoTWSatName {
    private static let map: [String: String] = [
        "AO-07": "AO-7", "ISS": "ARISS", "LILACSAT-2": "CAS-3H",
        "SONATE-2": "SONATE", "TAURUS 1": "TAURUS",
        "TEVEL2-1": "TEV2-1", "TEVEL2-2": "TEV2-2", "TEVEL2-3": "TEV2-3",
        "TEVEL2-4": "TEV2-4", "TEVEL2-5": "TEV2-5", "TEVEL2-6": "TEV2-6",
        "TEVEL2-7": "TEV2-7", "TEVEL2-8": "TEV2-8", "TEVEL2-9": "TEV2-9"
    ]

    static func resolve(_ name: String) -> String {
        let cands = candidates(name)
        for c in cands { if let m = map[c.uppercased()] { return m } }
        for c in cands.dropFirst() where c.count <= 6 { return c }   // parenthetical that fits beats truncation
        return String(name.prefix(6))
    }

    /// The name itself, then each parenthesised token.
    private static func candidates(_ name: String) -> [String] {
        var out = [name]
        var rest = Substring(name)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let inner = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty { out.append(inner) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }
}

enum LoTW {
    enum LoTWError: LocalizedError {
        case noCredential, importFailed(String), signFailed(String), gzipFailed, upload(String)
        var errorDescription: String? {
            switch self {
            case .noCredential: "No LoTW certificate imported. Import your .p12 in Log settings."
            case .importFailed(let m): "Could not open the LoTW certificate: \(m)"
            case .signFailed(let m): "Signing failed: \(m)"
            case .gzipFailed: "Could not compress the upload file."
            case .upload(let m): "Upload failed: \(m)"
            }
        }
    }

    // MARK: Credential storage

    private static var p12URL: URL {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("lotw.p12")
    }

    static func hasCredential() -> Bool { FileManager.default.fileExists(atPath: p12URL.path) }

    /// Validate and persist a .p12 + its passphrase. Returns the certificate's
    /// common name (callsign) if extractable.
    @discardableResult
    static func importP12(_ data: Data, passphrase: String) throws -> String {
        let (_, cert, _) = try loadIdentity(data: data, passphrase: passphrase)
        try data.write(to: p12URL, options: [.atomic, .completeFileProtection])
        OrbitSecretStore.set(passphrase, for: .lotwP12Passphrase)
        var cn: CFString?
        SecCertificateCopyCommonName(cert, &cn)
        return (cn as String?) ?? ""
    }

    static func clearCredential() {
        try? FileManager.default.removeItem(at: p12URL)
        OrbitSecretStore.set("", for: .lotwP12Passphrase)
    }

    private static func loadIdentity(data: Data, passphrase: String) throws -> (SecIdentity, SecCertificate, SecKey) {
        let opts = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]], let first = arr.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw LoTWError.importFailed("wrong passphrase or unsupported file (status \(status))")
        }
        let identity = identityAny as! SecIdentity
        var certRef: SecCertificate?
        var keyRef: SecKey?
        SecIdentityCopyCertificate(identity, &certRef)
        SecIdentityCopyPrivateKey(identity, &keyRef)
        guard let cert = certRef, let key = keyRef else {
            throw LoTWError.importFailed("certificate or private key missing")
        }
        return (identity, cert, key)
    }

    // MARK: Build

    /// Build a signed, gzipped .tq8 for the given QSOs.
    static func buildTQ8(_ qsos: [QSORecord], station: LoTWStation) throws -> Data {
        guard hasCredential() else { throw LoTWError.noCredential }
        let data = try Data(contentsOf: p12URL)
        let (_, cert, key) = try loadIdentity(data: data, passphrase: OrbitSecretStore.get(.lotwP12Passphrase))
        let certB64 = (SecCertificateCopyData(cert) as Data).base64EncodedString()

        var text = adifT("TQSL_IDENT", "TQSL OrbitDeck Lib(OrbitDeck) Config()") + "\n"
        text += adifT("Rec_Type", "tCERT")
        text += adifT("CERT_UID", "1")
        text += adifT("CERTIFICATE", certB64)
        text += "<eor>\n"
        text += stationRecord(station)
        for q in qsos {
            let sd = signData(q, station)
            let sig = try sign(sd, key: key)
            text += contactRecord(q, signData: sd, sigB64: sig)
        }
        guard let gz = Gzip.compress(Data(text.utf8)) else { throw LoTWError.gzipFailed }
        return gz
    }

    private static func sign(_ signdata: String, key: SecKey) throws -> String {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA1,
                                              Data(signdata.utf8) as CFData, &err) else {
            throw LoTWError.signFailed(err?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return (sig as Data).base64EncodedString()
    }

    // MARK: Upload

    /// POST a .tq8 to LoTW; returns the server's text response. Marks success on a
    /// 2xx without an obvious error token (the caller sets the uploaded flag).
    static func upload(_ tq8: Data) async throws -> LoTWResult {
        var req = URLRequest(url: URL(string: "https://lotw.arrl.org/lotw/upload")!)
        req.httpMethod = "POST"
        let boundary = "OrbitDeck-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"upfile\"; filename=\"orbitdeck.tq8\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(tq8)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        do {
            let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
            let text = String(data: data, encoding: .utf8) ?? ""
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let lower = text.lowercased()
            let ok = (200..<300).contains(code) && !lower.contains("error") && !lower.contains("rejected")
            return LoTWResult(ok: ok, signed: 0, message: text.isEmpty ? "HTTP \(code)" : text)
        } catch {
            throw LoTWError.upload(error.localizedDescription)
        }
    }

    // MARK: SIGNDATA (LoTW "LOTW V2.0" sigspec — ported from CardSat)

    /// Values-only, alphabetical-by-LoTW-field-name, station then contact, whole
    /// string uppercased. No tags, no separators.
    static func signData(_ q: QSORecord, _ st: LoTWStation) -> String {
        let dlM = Double(q.dlHz) / 1e6, ulM = Double(q.ulHz) / 1e6
        let (date, time) = textDateTime(q.utc)
        func subIs(_ f: String) -> Bool { !st.subdiv.isEmpty && st.subdivField == f }

        var s = ""
        if subIs("AU_STATE") { s += st.subdiv }
        if subIs("CA_PROVINCE") { s += st.subdiv }
        if subIs("CN_PROVINCE") { s += st.subdiv }
        if !st.cqz.isEmpty { s += st.cqz }
        if subIs("FI_KUNTA") { s += st.subdiv }
        if !st.grid.isEmpty { s += st.grid }
        if !st.iota.isEmpty { s += st.iota }
        if !st.ituz.isEmpty { s += st.ituz }
        if subIs("JA_PREFECTURE") { s += st.subdiv }
        if subIs("RU_OBLAST") { s += st.subdiv }
        let county = countyName(st.usCounty)
        if !county.isEmpty { s += county }
        if !st.usState.isEmpty { s += st.usState }
        // contact values (alphabetical): BAND, BAND_RX, CALL, FREQ, FREQ_RX, MODE, PROP_MODE, QSO_DATE, QSO_TIME, SAT_NAME
        s += ADIF.band(mhz: ulM)
        if dlM > 0 { s += ADIF.band(mhz: dlM) }
        s += q.call
        if ulM > 0 { s += String(format: "%.4f", ulM) }
        if dlM > 0 { s += String(format: "%.4f", dlM) }
        s += q.mode
        s += "SAT"
        s += date
        s += time
        if !q.sat.isEmpty { s += LoTWSatName.resolve(q.sat) }
        return s.uppercased()
    }

    // MARK: Records

    private static func stationRecord(_ st: LoTWStation) -> String {
        var r = adifT("Rec_Type", "tSTATION")
        r += adifSp("STATION_UID", "1")
        r += adifSp("CERT_UID", "1")
        r += adifSp("CALL", st.call)
        r += adifSp("DXCC", st.dxcc)
        r += adifSp("GRIDSQUARE", st.grid)
        r += adifSp("US_STATE", st.usState)
        r += adifSp("US_COUNTY", countyName(st.usCounty))
        r += adifSp("CQZ", st.cqz)
        r += adifSp("ITUZ", st.ituz)
        if !st.subdiv.isEmpty, !st.subdivField.isEmpty { r += adifSp(st.subdivField, st.subdiv) }
        r += adifSp("IOTA", st.iota)
        r += "<eor>\n"
        return r
    }

    private static func contactRecord(_ q: QSORecord, signData sd: String, sigB64: String) -> String {
        let dlM = Double(q.dlHz) / 1e6, ulM = Double(q.ulHz) / 1e6
        let (date, time) = textDateTime(q.utc)
        var r = adifT("Rec_Type", "tCONTACT")
        r += adifSp("STATION_UID", "1")
        r += adifSp("CALL", q.call)
        r += adifSp("BAND", ADIF.band(mhz: ulM))
        if dlM > 0 { r += adifSp("BAND_RX", ADIF.band(mhz: dlM)) }
        if ulM > 0 { r += adifSp("FREQ", String(format: "%.4f", ulM)) }
        if dlM > 0 { r += adifSp("FREQ_RX", String(format: "%.4f", dlM)) }
        r += adifSp("MODE", q.mode)
        r += adifSp("PROP_MODE", "SAT")
        r += adifSp("QSO_DATE", date)
        r += adifSp("QSO_TIME", time)
        if !q.sat.isEmpty { r += adifSp("SAT_NAME", LoTWSatName.resolve(q.sat)) }
        r += adifTy("SIGN_LOTW_V2.0", "6", sigB64)
        r += adifT("SIGNDATA", sd)
        r += "<eor>\n"
        return r
    }

    // MARK: ADIF/GABBI primitives (tight vs. space-suffixed, matching TQSL)

    private static func adifT(_ name: String, _ v: String) -> String {
        "<\(name):\(v.utf8.count)>\(v)"
    }
    private static func adifSp(_ name: String, _ v: String) -> String {
        v.isEmpty ? "" : "<\(name):\(v.utf8.count)>\(v) "
    }
    private static func adifTy(_ name: String, _ type: String, _ v: String) -> String {
        "<\(name):\(v.utf8.count):\(type)>\(v)"
    }

    /// County name alone (LoTW US_COUNTY), stripping a leading "ST," if present.
    private static func countyName(_ raw: String) -> String {
        guard let comma = raw.firstIndex(of: ",") else { return raw.trimmingCharacters(in: .whitespaces) }
        return String(raw[raw.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
    }

    /// TQSL text date/time: "YYYY-MM-DD" and "HH:MM:SSZ" (UTC).
    private static func textDateTime(_ date: Date) -> (String, String) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let d = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let t = String(format: "%02d:%02d:%02dZ", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return (d, t)
    }
}
