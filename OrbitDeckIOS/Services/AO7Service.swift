import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AO7FitResult: Sendable {
    let periodSeconds: Double
    let referenceSwitch: Date
    let flip: Int
    let agreementPercent: Double
    let phaseUncertaintySeconds: Double
    let modeNow: Int
    let nextSwitch: Date
    let previousSwitch: Date
    let observationCount: Int
    let positiveCount: Int
    let negativeCount: Int
    let observedSwitchCount: Int
    let note: String
    let nearBoundary: Bool

    var modeName: String {
        modeNow == 0 ? "Mode A (145 up / 29 down)" : "Mode B (432 up / 145 down)"
    }

    var timeToSwitch: TimeInterval {
        max(0, nextSwitch.timeIntervalSinceNow)
    }
}

private struct AO7Observation: Sendable {
    let date: Date
    let mode: Int
    let negative: Bool
}

enum AO7ServiceError: LocalizedError {
    case badResponse
    case noReports
    case noPositiveReports

    var errorDescription: String? {
        switch self {
        case .badResponse: "AMSAT status API returned an unusable response."
        case .noReports: "No usable AO-7 mode reports were returned."
        case .noPositiveReports: "AO-7 reports contained no positive observations to fit."
        }
    }
}

enum AO7Service {
    static let ao7Norad: UInt = 7530
    private static let reportBase = "https://www.amsat.org/status/api/v1/reports.php"
    private static let modeNames = [0: "AO-7_[V/a]", 1: "AO-7_[U/v]"]
    private static let positiveWeight = 1.0
    private static let negativeWeight = 0.35

    static func fetchAndFit(now: Date = .now, hours: Int = 30 * 24, sinceSunlightStart: Date? = nil) async throws -> AO7FitResult {
        async let modeA = fetchReports(mode: 0, hours: hours)
        async let modeB = fetchReports(mode: 1, hours: hours)
        let (a, b) = try await (modeA, modeB)
        var observations = (a + b).sorted { $0.date < $1.date }
        guard !observations.isEmpty else { throw AO7ServiceError.noReports }
        // AO-7 has no batteries: its A/B mode timer only free-runs during
        // continuous sunlight and its phase resets across eclipse power-cycles.
        // Fitting only the current continuous-sunlight window removes stale-phase
        // reports — but fall back to the full set if that window is too sparse.
        if let start = sinceSunlightStart {
            let windowed = observations.filter { $0.date >= start }
            if windowed.reduce(0, { $0 + ($1.negative ? 0 : 1) }) >= 6 {
                observations = windowed
            }
        }
        return try fit(observations, now: now)
    }

    private static func fetchReports(mode: Int, hours: Int) async throws -> [AO7Observation] {
        guard let apiName = modeNames[mode] else { return [] }
        var components = URLComponents(string: reportBase)!
        components.queryItems = [
            URLQueryItem(name: "name", value: apiName),
            URLQueryItem(name: "hours", value: String(hours)),
            URLQueryItem(name: "limit", value: "500")
        ]
        guard let url = components.url else { throw AO7ServiceError.badResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("OrbitDeck-iOS/0.9.7", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AO7ServiceError.badResponse
        }
        return parseReports(data: data, mode: mode)
    }

    private static func parseReports(data: Data, mode: Int) -> [AO7Observation] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let array: [Any]
        if let a = root as? [Any] {
            array = a
        } else if let dict = root as? [String: Any] {
            array = (dict["reports"] as? [Any]) ?? (dict["data"] as? [Any]) ?? []
        } else {
            array = []
        }

        return array.compactMap { item in
            guard let record = item as? [String: Any] else { return nil }
            let stamp = record["reported_time"] ?? record["time"] ?? record["timestamp"] ?? record["date"]
            guard let date = parseDate(stamp) else { return nil }
            let raw = String(describing: record["report"] ?? record["status"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return nil }
            return AO7Observation(date: date, mode: mode,
                                  negative: raw.lowercased().hasPrefix("not"))
        }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard var text = value as? String else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")) {
                return date
            }
        }
        return nil
    }

    private static func score(_ observations: [AO7Observation], period: Double,
                              reference: TimeInterval, flip: Int) -> Double {
        var total = 0.0
        for observation in observations {
            let k = floor((observation.date.timeIntervalSince1970 - reference) / period)
            let predicted = (Int(k) & 1) ^ flip
            if observation.negative {
                if predicted != observation.mode { total += negativeWeight }
            } else if predicted == observation.mode {
                total += positiveWeight
            }
        }
        return total
    }

    private static func fit(_ observations: [AO7Observation], now: Date) throws -> AO7FitResult {
        let positiveCount = observations.reduce(0) { $0 + ($1.negative ? 0 : 1) }
        guard positiveCount > 0 else { throw AO7ServiceError.noPositiveReports }

        let periodMin = 12.0 * 3600.0
        let periodMax = 30.0 * 3600.0
        let coarsePeriodStep = 300.0
        let coarsePhaseStep = 1800.0
        let finePeriodStep = 30.0
        let finePhaseStep = 60.0
        let referenceBase = observations[0].date.timeIntervalSince1970
        let weightTotal = observations.reduce(0.0) {
            $0 + ($1.negative ? negativeWeight : positiveWeight)
        }

        var bestScore = -1.0
        var bestPeriod = periodMin
        var bestReference = referenceBase
        var bestFlip = 0

        var period = periodMin
        while period <= periodMax {
            var offset = 0.0
            while offset < period {
                let reference = referenceBase + offset
                for flip in 0...1 {
                    let current = score(observations, period: period,
                                        reference: reference, flip: flip)
                    if current > bestScore {
                        bestScore = current
                        bestPeriod = period
                        bestReference = reference
                        bestFlip = flip
                    }
                }
                offset += coarsePhaseStep
            }
            period += coarsePeriodStep
        }

        let coarseBestPeriod = bestPeriod
        let coarseBestReference = bestReference
        period = coarseBestPeriod - coarsePeriodStep
        while period <= coarseBestPeriod + coarsePeriodStep {
            if period >= periodMin, period <= periodMax {
                var reference = coarseBestReference - coarsePhaseStep
                while reference <= coarseBestReference + coarsePhaseStep {
                    let current = score(observations, period: period,
                                        reference: reference, flip: bestFlip)
                    if current > bestScore {
                        bestScore = current
                        bestPeriod = period
                        bestReference = reference
                    }
                    reference += finePhaseStep
                }
            }
            period += finePeriodStep
        }

        var lowerUncertainty = 0.0
        var delta = finePhaseStep
        while delta <= bestPeriod / 2.0 {
            if score(observations, period: bestPeriod,
                     reference: bestReference - delta, flip: bestFlip) < bestScore - positiveWeight {
                break
            }
            lowerUncertainty = delta
            delta += finePhaseStep
        }
        var upperUncertainty = 0.0
        delta = finePhaseStep
        while delta <= bestPeriod / 2.0 {
            if score(observations, period: bestPeriod,
                     reference: bestReference + delta, flip: bestFlip) < bestScore - positiveWeight {
                break
            }
            upperUncertainty = delta
            delta += finePhaseStep
        }
        let phaseUncertainty = 0.5 * (lowerUncertainty + upperUncertainty)

        let nowTime = now.timeIntervalSince1970
        let kNow = floor((nowTime - bestReference) / bestPeriod)
        let previousSwitchTime = bestReference + kNow * bestPeriod
        let nextSwitchTime = bestReference + (kNow + 1.0) * bestPeriod
        let modeNow = (Int(kNow) & 1) ^ bestFlip

        var observedSwitches = 0
        var lastPositiveMode: Int?
        for observation in observations where !observation.negative {
            if let lastPositiveMode, lastPositiveMode != observation.mode { observedSwitches += 1 }
            lastPositiveMode = observation.mode
        }

        let agreement = weightTotal > 0 ? 100.0 * bestScore / weightTotal : 0
        let margin = max(phaseUncertainty, 900.0)
        let nearBoundary = (nextSwitchTime - nowTime) < margin || (nowTime - previousSwitchTime) < margin
        let note: String
        if nearBoundary {
            note = "Near a switch: mode uncertain right now"
        } else if observedSwitches < 2 || positiveCount < 6 {
            note = "Low confidence (few reports)"
        } else if agreement < 75 {
            note = "Reports disagree; estimate approximate"
        } else if phaseUncertainty > 0.10 * bestPeriod {
            note = "Phase loosely constrained"
        } else {
            note = "Estimate from AMSAT report timestamps"
        }

        return AO7FitResult(
            periodSeconds: bestPeriod,
            referenceSwitch: Date(timeIntervalSince1970: bestReference),
            flip: bestFlip,
            agreementPercent: agreement,
            phaseUncertaintySeconds: phaseUncertainty,
            modeNow: modeNow,
            nextSwitch: Date(timeIntervalSince1970: nextSwitchTime),
            previousSwitch: Date(timeIntervalSince1970: previousSwitchTime),
            observationCount: observations.count,
            positiveCount: positiveCount,
            negativeCount: observations.count - positiveCount,
            observedSwitchCount: observedSwitches,
            note: note,
            nearBoundary: nearBoundary
        )
    }
}
