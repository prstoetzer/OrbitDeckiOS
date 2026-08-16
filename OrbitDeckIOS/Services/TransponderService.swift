import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum TransponderServiceError: LocalizedError {
    case badResponse(Int)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "SatNOGS returned HTTP \(code)."
        case .invalidJSON: "SatNOGS returned an unexpected response."
        }
    }
}

struct TransponderService {
    static func fetch(norad: UInt) async throws -> [TransponderRecord] {
        var comps = URLComponents(string: "https://db.satnogs.org/api/transmitters/")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "satellite__norad_cat_id", value: String(norad))
        ]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 30
        request.setValue("OrbitDeck-iOS/0.9.7", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TransponderServiceError.badResponse(http.statusCode)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TransponderServiceError.invalidJSON
        }
        return parseRows(rows)
    }

    static func fetchAll() async throws -> [UInt: [TransponderRecord]] {
        var comps = URLComponents(string: "https://db.satnogs.org/api/transmitters/")!
        comps.queryItems = [URLQueryItem(name: "format", value: "json")]
        var request = URLRequest(url: comps.url!)
        request.timeoutInterval = 60
        request.setValue("OrbitDeck-iOS/0.9.7", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TransponderServiceError.badResponse(http.statusCode)
        }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw TransponderServiceError.invalidJSON
        }
        var output: [UInt: [TransponderRecord]] = [:]
        for row in rows {
            let norad: UInt?
            if let n = row["norad_cat_id"] as? NSNumber { norad = UInt(n.uint64Value) }
            else if let text = row["norad_cat_id"] as? String { norad = UInt(text) }
            else { norad = nil }
            guard let norad, let parsed = parseRow(row) else { continue }
            output[norad, default: []].append(parsed)
        }
        return output
    }

    private static func parseRows(_ rows: [[String: Any]]) -> [TransponderRecord] {
        rows.compactMap(parseRow)
    }

    private static func parseRow(_ row: [String: Any]) -> TransponderRecord? {
        // Keep active AND inactive transmitters (the reference apps show both);
        // only skip rows with no tunable downlink frequency.
        guard int64(row["downlink_low"]) > 0 else { return nil }
        let id = (row["uuid"] as? String)
            ?? (row["id"] as? NSNumber)?.stringValue
            ?? UUID().uuidString
        let description = (row["description"] as? String) ?? ""
        let mode = (row["mode"] as? String) ?? ""
        let type = (row["type"] as? String) ?? ""
        let service = (row["service"] as? String) ?? ""
        let invert = (row["invert"] as? Bool) ?? false
        return TransponderRecord(
            id: id,
            description: description,
            downlinkLow: int64(row["downlink_low"]),
            downlinkHigh: int64(row["downlink_high"]),
            uplinkLow: int64(row["uplink_low"]),
            uplinkHigh: int64(row["uplink_high"]),
            mode: mode,
            invert: invert,
            type: type,
            baud: double(row["baud"]),
            service: service
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func double(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        return 0
    }
}
