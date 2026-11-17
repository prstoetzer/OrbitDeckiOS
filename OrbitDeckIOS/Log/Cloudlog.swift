import Foundation

// ===========================================================================
//  Cloudlog.swift — Cloudlog / Wavelog JSON-API upload
//
//  Posts ADIF to a self-hosted Cloudlog/Wavelog instance in one request (no
//  ESP32-style batching). The API key lives in the Keychain; URL + station
//  profile id are in CloudlogConfig.
// ===========================================================================

enum Cloudlog {
    enum CloudlogError: LocalizedError, Equatable {
        case notConfigured, insecureURL(String), http(Int, String), rejected(String), network(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Set the Cloudlog URL, station profile ID and API key in Log settings."
            case .insecureURL(let m): m
            case .http(let c, let m): "Cloudlog returned HTTP \(c)" + (m.isEmpty ? "." : ": \(m)")
            case .rejected(let m): m
            case .network(let m): "Cloudlog upload failed: \(m)"
            }
        }
    }

    static let httpsRequiredMessage = "Use https:// for internet hosts. Plain http:// is only allowed for a server on your local network."
    static let cleartextWarning = "Unencrypted: your API key is sent in plain text on this network."

    /// Upload the given QSOs; returns the count the server confirmed. Throws unless the
    /// server confirms it imported every record, so the caller marks none on any doubt.
    @discardableResult
    static func upload(_ qsos: [QSORecord], config: CloudlogConfig, apiKey: String) async throws -> Int {
        guard !config.url.isEmpty, !apiKey.isEmpty, !qsos.isEmpty else { throw CloudlogError.notConfigured }
        let url: URL
        switch checkURL(config.url) {
        case .secure(let u), .cleartextLocal(let u): url = u
        case .blocked(let reason): throw CloudlogError.insecureURL(reason)
        case nil: throw CloudlogError.notConfigured
        }

        // Cloudlog's API takes the key in the JSON body (there's no header form), which
        // is why the URL policy above insists on https outside the local network.
        let payload: [String: Any] = [
            "key": apiKey,
            "station_profile_id": config.stationProfileId,
            "type": "adif",
            "string": ADIF.export(qsos)
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data, code: Int
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            data = d
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection {
            throw CloudlogError.insecureURL(httpsRequiredMessage)
        } catch {
            throw CloudlogError.network(error.localizedDescription)
        }
        switch classify(statusCode: code, body: data, sent: qsos.count) {
        case .success(let n): return n
        case .failure(let e): throw e
        }
    }

    // MARK: Response

    enum UploadOutcome: Equatable {
        case success(Int)
        case failure(CloudlogError)
    }

    /// Classify the server's reply to a batch of `sent` records. Success only when the
    /// status says created/success AND the imported count (Cloudlog `imported_count`,
    /// Wavelog `adif_count`) equals `sent` with no error count and no error messages.
    /// Both servers answer 201 even when individual records were rejected (duplicates,
    /// invalid fields), listing them in `messages`, so a bare 2xx proves nothing.
    static func classify(statusCode: Int, body: Data, sent: Int) -> UploadOutcome {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let messages = json.map(serverMessages) ?? []
        guard (200..<300).contains(statusCode) else {
            var detail = messages.joined(separator: "\n")
            if detail.isEmpty, json == nil { detail = snippet(body) }
            return .failure(.http(statusCode, detail))
        }
        guard let json else {
            return .failure(.rejected("Cloudlog sent an unexpected reply (not JSON), so no QSOs were marked as uploaded."
                                      + (snippet(body).isEmpty ? "" : " Reply: \(snippet(body))")))
        }
        let status = (json["status"] as? String ?? "").lowercased()
        let imported = intValue(json["imported_count"]) ?? intValue(json["adif_count"])
        let errorCount = errorCount(json["adif_errors"])
        if ["created", "success", "ok"].contains(status), imported == sent, errorCount == 0, messages.isEmpty {
            return .success(sent)
        }
        var lines: [String] = []
        if let imported, imported != sent {
            lines.append("Cloudlog accepted \(imported) of \(sent) QSO(s).")
        } else if imported == nil {
            lines.append("Cloudlog didn't report how many QSOs it imported.")
        }
        if errorCount > 0 { lines.append("\(errorCount) record(s) had errors.") }
        if !status.isEmpty, !["created", "success", "ok"].contains(status) { lines.append("Status: \(status).") }
        lines.append(contentsOf: messages.prefix(10))
        if messages.count > 10 { lines.append("… and \(messages.count - 10) more.") }
        lines.append("No QSOs were marked as uploaded; records the server already has may show as duplicates next time.")
        return .failure(.rejected(lines.joined(separator: "\n")))
    }

    /// Human-readable messages in a reply: `reason`, `message(s)`, and `adif_errors`
    /// when it's a list. Blank entries (Cloudlog adds one per clean record) are dropped.
    private static func serverMessages(_ json: [String: Any]) -> [String] {
        var out: [String] = []
        func collect(_ v: Any?) {
            switch v {
            case let s as String: out.append(s)
            case let a as [Any]: a.forEach(collect)
            case let d as [String: Any]: d.values.forEach(collect)
            default: break
            }
        }
        collect(json["reason"]); collect(json["message"]); collect(json["messages"])
        if intValue(json["adif_errors"]) == nil { collect(json["adif_errors"]) }     // a count isn't a message
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// `adif_errors` as a count: a number, a numeric string or a list of errors.
    private static func errorCount(_ v: Any?) -> Int {
        if let n = intValue(v) { return n }
        if let a = v as? [Any] { return a.count }
        if let d = v as? [String: Any] { return d.count }
        return 0
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// The start of a non-JSON reply (e.g. a PHP error page), on one line.
    private static func snippet(_ body: Data) -> String {
        let text = String(decoding: body.prefix(200), as: UTF8.self)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    // MARK: URL policy

    enum URLCheck: Equatable {
        case secure(URL)            // https
        case cleartextLocal(URL)    // http to a local-network host: allowed, with a warning
        case blocked(String)        // reason shown to the user
    }

    /// Check a user-entered instance URL and resolve its QSO endpoint; nil when empty.
    /// https is required except for hosts on the local network (private / link-local /
    /// loopback addresses, unqualified names, .local), where http is allowed because
    /// many shack servers have no certificate. App Transport Security would refuse http
    /// to an internet hostname anyway; a public IP literal would slip past ATS and send
    /// the key across the internet unencrypted, so it's blocked here too.
    static func checkURL(_ base: String) -> URLCheck? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = endpoint(for: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else {
            return .blocked("Enter the full Cloudlog address, starting with https://")
        }
        switch scheme {
        case "https": return .secure(url)
        case "http": return isLocalNetworkHost(host) ? .cleartextLocal(url) : .blocked(httpsRequiredMessage)
        default: return .blocked("The Cloudlog address must start with https://")
        }
    }

    /// Whether `host` is on the local network: RFC 1918 / link-local / loopback IPv4,
    /// IPv6 loopback / ULA (fc00::/7) / link-local (fe80::/10), an unqualified name or
    /// a .local (mDNS) name.
    static func isLocalNetworkHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }    // IPv6 zone id
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let a = withUnsafeBytes(of: v4) { Array($0) }
            return a[0] == 10 || a[0] == 127
                || (a[0] == 172 && (16...31).contains(a[1]))
                || (a[0] == 192 && a[1] == 168)
                || (a[0] == 169 && a[1] == 254)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
            return loopback || (b[0] & 0xFE) == 0xFC || (b[0] == 0xFE && (b[1] & 0xC0) == 0x80)
        }
        // A dotted all-numeric name that isn't a valid IPv4 literal: treat as public.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return false }
        return host == "localhost" || !host.contains(".") || host.hasSuffix(".local")
    }

    /// Resolve the QSO endpoint from a user-entered base URL.
    private static func endpoint(for base: String) -> URL? {
        var s = base.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api/qso") { return URL(string: s) }
        if s.hasSuffix("index.php") { return URL(string: s + "/api/qso") }
        return URL(string: s + "/index.php/api/qso")
    }
}
