import Foundation

// ===========================================================================
//  Cloudlog.swift — Cloudlog / Wavelog JSON-API upload
//
//  Posts ADIF to a self-hosted Cloudlog/Wavelog instance in one request (no
//  ESP32-style batching). The API key lives in the Keychain; URL + station
//  profile id are in CloudlogConfig.
// ===========================================================================

enum Cloudlog {
    enum CloudlogError: LocalizedError {
        case notConfigured, http(Int, String), network(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Set the Cloudlog URL, station profile ID and API key in Log settings."
            case .http(let c, let m): "Cloudlog returned HTTP \(c): \(m)"
            case .network(let m): "Cloudlog upload failed: \(m)"
            }
        }
    }

    /// Upload the given QSOs; returns the count sent on success.
    @discardableResult
    static func upload(_ qsos: [QSORecord], config: CloudlogConfig, apiKey: String) async throws -> Int {
        guard !config.url.isEmpty, !apiKey.isEmpty, !qsos.isEmpty else { throw CloudlogError.notConfigured }
        guard let url = endpoint(for: config.url) else { throw CloudlogError.notConfigured }

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

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(code) else { throw CloudlogError.http(code, text) }
            return qsos.count
        } catch let e as CloudlogError {
            throw e
        } catch {
            throw CloudlogError.network(error.localizedDescription)
        }
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
