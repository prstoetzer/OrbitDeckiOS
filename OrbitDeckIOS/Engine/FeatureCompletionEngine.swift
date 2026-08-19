import Foundation
import SatelliteKit

struct EMEBandAnalysisRow: Identifiable, Sendable {
    let id: Double
    let band: String
    let frequencyMHz: Double
    let dopplerHz: Double
    let faradayDegrees: Double
    let skyTemperatureK: Double
    let librationSpreadHz: Double
    let pathLossDb: Double
}

struct EMEPlanRow: Identifiable, Sendable {
    let id: Date
    let date: Date
    let declinationDegrees: Double
    let degradationDb: Double
    let distanceKm: Double
    let good: Bool
}

struct ConjunctionCurvePoint: Identifiable, Sendable {
    let id: Date
    let date: Date
    let separationKm: Double
}

struct ConjunctionDetailSnapshot: Sendable {
    let date: Date
    let missDistanceKm: Double
    let relativeVelocityKmS: Double
    let primaryAltitudeKm: Double
    let secondaryAltitudeKm: Double
    let primarySpeedKmS: Double
    let secondarySpeedKmS: Double
    let closingRateKmS: Double
    let curve: [ConjunctionCurvePoint]

    var awarenessLabel: String {
        if missDistanceKm < 10 { return "Very close GP screening result" }
        if missDistanceKm < 100 { return "Close GP screening result" }
        if missDistanceKm < 800 { return "Within desktop awareness threshold" }
        return "Wide approach"
    }
}

struct RadioLinkBudgetSnapshot: Sendable {
    let txPowerDbm: Double
    let eirpDbm: Double
    let freeSpacePathLossDb: Double
    let receivedPowerDbm: Double
    let propagationDelayMs: Double
}

struct RadioPlaybookRow: Identifiable, Sendable {
    let id: Date
    let date: Date
    let azimuthDegrees: Double
    let elevationDegrees: Double
    let rangeRateKmS: Double
    let receiveHz: Int64
    let transmitHz: Int64
    let mode: String
}

struct PassbandPlanRow: Identifiable, Sendable {
    let id: Int
    let percent: Int
    let downlinkHz: Int64
    let uplinkHz: Int64
}


struct SatelliteEclipsePeriod: Identifiable, Sendable {
    let id: Date
    let enter: Date
    let exit: Date
    let durationSeconds: Double
    let betaAngleDegrees: Double
}

struct SatelliteEclipseDailySummary: Identifiable, Sendable {
    let id: Date
    let date: Date
    let count: Int
    let totalSeconds: Double
    let longestSeconds: Double
    let percentOfDay: Double
    let betaAngleDegrees: Double
}

struct FeatureCompletionEngine {
    private static let speedOfLightMS = 299_792_458.0
    private static let earthRadiusKm = 6378.135
    private static let perigeeReferenceKm = 356_500.0

    // MARK: - EME specialist parity

    static func moonDeclinationDegrees(at date: Date) -> Double {
        let v = FeatureEngine.moonSolution(date.julianDate).vector
        return atan2(v.z, hypot(v.x, v.y)) * 180 / .pi
    }

    static func moonGalacticLatitudeDegrees(at date: Date) -> Double {
        let v = FeatureEngine.moonSolution(date.julianDate).vector
        let ra = atan2(v.y, v.x)
        let dec = asin(max(-1, min(1, v.z)))
        let raGP = 192.85948 * .pi / 180
        let decGP = 27.12825 * .pi / 180
        let sinB = sin(dec) * sin(decGP) + cos(dec) * cos(decGP) * cos(ra - raGP)
        return asin(max(-1, min(1, sinB))) * 180 / .pi
    }

    static func emeFaradayDegrees(frequencyMHz: Double, solarFlux: Double?) -> Double {
        let flux = (solarFlux ?? 120) > 0 ? (solarFlux ?? 120) : 120
        let f = max(1, frequencyMHz)
        return 90.0 * (flux / 120.0) * (144.0 * 144.0) / (f * f)
    }

    static func emeSkyTemperatureK(at date: Date, frequencyMHz: Double) -> Double {
        let f = max(1, frequencyMHz)
        let b = abs(moonGalacticLatitudeDegrees(at: date))
        let cold = 3.0 + 200.0 * pow(144.0 / f, 2.5)
        let planeExcess = b < 30 ? 1.0 - b / 30.0 : 0.0
        let hot = 2000.0 * pow(144.0 / f, 2.5) * planeExcess
        return cold + hot
    }

    static func emeLibrationSpreadHz(frequencyMHz: Double) -> Double {
        2.5 * max(1, frequencyMHz) / 144.0
    }

    static func emePathDegradationDb(at date: Date) -> Double {
        let distance = FeatureEngine.sunMoon(site: ObserverSite(), at: date).moonDistanceKm
        return 40.0 * log10(distance / perigeeReferenceKm)
    }

    static func emeSunSeparationDegrees(site: ObserverSite, at date: Date) -> Double {
        let sm = FeatureEngine.sunMoon(site: site, at: date)
        let mel = sm.moonElevation * .pi / 180
        let sel = sm.sunElevation * .pi / 180
        let daz = (sm.moonAzimuth - sm.sunAzimuth) * .pi / 180
        let cosine = sin(mel) * sin(sel) + cos(mel) * cos(sel) * cos(daz)
        return acos(max(-1, min(1, cosine))) * 180 / .pi
    }

    static func emeGroundGainDescription(elevationDegrees: Double) -> String {
        if elevationDegrees <= 0 { return "Moon down" }
        if elevationDegrees < 8 { return "ground gain ACTIVE (el < 8°)" }
        return "no ground gain (el ≥ 8°)"
    }

    static func emeBandAnalysis(
        site: ObserverSite,
        at date: Date = .now,
        solarFlux: Double? = nil
    ) -> [EMEBandAnalysisRow] {
        let bands: [(String, Double)] = [
            ("50 MHz", 50), ("144 MHz", 144), ("432 MHz", 432),
            ("1296 MHz", 1296), ("10368 MHz", 10368)
        ]
        return bands.map { name, mhz in
            let base = FeatureEngine.emeSnapshot(site: site, frequencyMHz: mhz, at: date)
            return EMEBandAnalysisRow(
                id: mhz,
                band: name,
                frequencyMHz: mhz,
                dopplerHz: base.selfEchoDopplerHz,
                faradayDegrees: emeFaradayDegrees(frequencyMHz: mhz, solarFlux: solarFlux),
                skyTemperatureK: emeSkyTemperatureK(at: date, frequencyMHz: mhz),
                librationSpreadHz: emeLibrationSpreadHz(frequencyMHz: mhz),
                pathLossDb: base.pathLossDb
            )
        }
    }

    static func emePlan(from start: Date = .now, days: Int = 90) -> [EMEPlanRow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: start)
        guard let noon = calendar.date(byAdding: .hour, value: 12, to: day) else { return [] }
        return (0..<max(1, days)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: noon) else { return nil }
            let sm = FeatureEngine.sunMoon(site: ObserverSite(), at: date)
            let degradation = 40.0 * log10(sm.moonDistanceKm / perigeeReferenceKm)
            let declination = moonDeclinationDegrees(at: date)
            return EMEPlanRow(id: date, date: date,
                              declinationDegrees: declination,
                              degradationDb: degradation,
                              distanceKm: sm.moonDistanceKm,
                              good: declination > 15 && degradation < 1.0)
        }
    }

    // MARK: - Illumination / eclipse ephemeris parity

    static func satelliteEclipses(
        satellite record: SatelliteRecord,
        from start: Date = .now,
        days: Int = 7,
        coarseStepSeconds: TimeInterval = 60
    ) throws -> [SatelliteEclipsePeriod] {
        let safeDays = max(1, min(days, 30))
        let sat = Satellite(elements: record.elements)
        let end = start.addingTimeInterval(Double(safeDays) * 86400)
        let step = max(10, coarseStepSeconds)

        func lit(_ date: Date) throws -> Bool {
            let r = try sat.position(julianDays: date.julianDate)
            return OrbitPredictor.isSunlit(position: r, julianDay: date.julianDate)
        }

        func refine(_ low: Date, _ high: Date, lowState: Bool) throws -> Date {
            var lo = low
            var hi = high
            for _ in 0..<32 {
                let mid = Date(timeIntervalSince1970: (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
                if try lit(mid) == lowState { lo = mid } else { hi = mid }
                if hi.timeIntervalSince(lo) <= 1 { break }
            }
            return Date(timeIntervalSince1970: (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
        }

        var periods: [SatelliteEclipsePeriod] = []
        var t0 = start
        var state0 = try lit(t0)
        var currentEnter: Date? = state0 ? nil : start

        while t0 < end {
            let t1 = min(end, t0.addingTimeInterval(step))
            let state1 = try lit(t1)
            if state0 != state1 {
                let boundary = try refine(t0, t1, lowState: state0)
                if state0 && !state1 {
                    currentEnter = boundary
                } else if !state0 && state1, let enter = currentEnter {
                    let mid = Date(timeIntervalSince1970: (enter.timeIntervalSince1970 + boundary.timeIntervalSince1970) / 2)
                    periods.append(.init(
                        id: enter, enter: enter, exit: boundary,
                        durationSeconds: max(0, boundary.timeIntervalSince(enter)),
                        betaAngleDegrees: OrbitPredictor.betaAngle(record: record, julianDay: mid.julianDate)
                    ))
                    currentEnter = nil
                }
            }
            t0 = t1
            state0 = state1
        }
        if let enter = currentEnter {
            let mid = Date(timeIntervalSince1970: (enter.timeIntervalSince1970 + end.timeIntervalSince1970) / 2)
            periods.append(.init(
                id: enter, enter: enter, exit: end,
                durationSeconds: max(0, end.timeIntervalSince(enter)),
                betaAngleDegrees: OrbitPredictor.betaAngle(record: record, julianDay: mid.julianDate)
            ))
        }
        return periods
    }

    static func satelliteEclipseDailySummary(
        satellite: SatelliteRecord,
        periods: [SatelliteEclipsePeriod],
        from start: Date = .now,
        days: Int = 7
    ) -> [SatelliteEclipseDailySummary] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let day0 = cal.startOfDay(for: start)
        return (0..<max(1, min(days, 30))).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: day0),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
            let overlaps = periods.compactMap { p -> Double? in
                let a = max(p.enter, day)
                let b = min(p.exit, next)
                let duration = b.timeIntervalSince(a)
                return duration > 0 ? duration : nil
            }
            let total = overlaps.reduce(0, +)
            let noon = day.addingTimeInterval(12 * 3600)
            return .init(
                id: day, date: day, count: overlaps.count, totalSeconds: total,
                longestSeconds: overlaps.max() ?? 0, percentOfDay: total / 86400 * 100,
                betaAngleDegrees: OrbitPredictor.betaAngle(record: satellite, julianDay: noon.julianDate)
            )
        }
    }

    // MARK: - Conjunction specialist detail

    static func conjunctionDetail(
        primary: SatelliteRecord,
        secondary: SatelliteRecord,
        event: ConjunctionRecord,
        halfWindowSeconds: TimeInterval = 600,
        stepSeconds: TimeInterval = 30
    ) throws -> ConjunctionDetailSnapshot {
        let a = Satellite(elements: primary.elements)
        let b = Satellite(elements: secondary.elements)
        let sa = try state(a, at: event.date)
        let sb = try state(b, at: event.date)
        let primaryAltitude = magnitude(sa.position) - earthRadiusKm
        let secondaryAltitude = magnitude(sb.position) - earthRadiusKm
        let primarySpeed = magnitude(sa.velocity)
        let secondarySpeed = magnitude(sb.velocity)
        let relSpeed = separation(sa.velocity, sb.velocity)

        let before = try separation(state(a, at: event.date.addingTimeInterval(-1)).position,
                                    state(b, at: event.date.addingTimeInterval(-1)).position)
        let after = try separation(state(a, at: event.date.addingTimeInterval(1)).position,
                                   state(b, at: event.date.addingTimeInterval(1)).position)
        let closingRate = (after - before) / 2.0

        var curve: [ConjunctionCurvePoint] = []
        var t = event.date.addingTimeInterval(-halfWindowSeconds)
        let end = event.date.addingTimeInterval(halfWindowSeconds)
        while t <= end {
            let p1 = try state(a, at: t).position
            let p2 = try state(b, at: t).position
            curve.append(.init(id: t, date: t, separationKm: separation(p1, p2)))
            t = t.addingTimeInterval(stepSeconds)
        }

        return ConjunctionDetailSnapshot(
            date: event.date,
            missDistanceKm: event.missDistanceKm,
            relativeVelocityKmS: relSpeed,
            primaryAltitudeKm: primaryAltitude,
            secondaryAltitudeKm: secondaryAltitude,
            primarySpeedKmS: primarySpeed,
            secondarySpeedKmS: secondarySpeed,
            closingRateKmS: closingRate,
            curve: curve
        )
    }

    // MARK: - Radio operating parity

    static func linkBudget(
        rangeKm: Double,
        frequencyHz: Double,
        txPowerW: Double,
        txGainDb: Double,
        rxGainDb: Double,
        lineLossDb: Double,
        otherLossDb: Double = 0
    ) -> RadioLinkBudgetSnapshot {
        let txPowerDbm = txPowerW > 0 ? 10.0 * log10(txPowerW * 1000.0) : -999
        let eirp = txPowerDbm + txGainDb
        let fspl: Double
        if rangeKm > 0 && frequencyHz > 0 {
            fspl = 20 * log10(rangeKm * 1000) + 20 * log10(frequencyHz)
                + 20 * log10(4 * .pi / speedOfLightMS)
        } else {
            fspl = 0
        }
        let rx = eirp - fspl - lineLossDb - otherLossDb + rxGainDb
        let delay = rangeKm > 0 ? rangeKm * 1_000_000 / speedOfLightMS : 0
        return RadioLinkBudgetSnapshot(txPowerDbm: txPowerDbm, eirpDbm: eirp,
                                       freeSpacePathLossDb: fspl,
                                       receivedPowerDbm: rx,
                                       propagationDelayMs: delay)
    }

    static func radioPlaybook(
        satellite: SatelliteRecord,
        observer: ObserverSite,
        pass: PredictedPass,
        transponder: TransponderRecord,
        intervalSeconds: TimeInterval = 60,
        hold: String = "downlink",
        passbandPercent: Double = 50,
        calDlHz: Int64 = 0,
        calUlHz: Int64 = 0
    ) throws -> [RadioPlaybookRow] {
        let fraction = max(0, min(1, passbandPercent / 100))
        let offset = transponder.isLinear ? Int64((Double(transponder.bandwidth) * fraction).rounded()) : 0
        let nominal = OrbitPredictor.passbandFrequencies(transponder, offsetHz: offset)
        let sign = transponder.invert ? -1.0 : 1.0
        // Operator's own combined oscillator error (radio + satellite), measurable
        // from either leg. Both offsets fold into one overall correction referred to
        // the downlink (uplink contribution sign-flipped for inverting transponders)
        // and applied only to the receive dial; the transmit dial is left on the
        // computed frequency.
        let overallCal = Double(calDlHz) + sign * Double(calUlHz)
        var rows: [RadioPlaybookRow] = []
        var t = pass.aos
        while t <= pass.los.addingTimeInterval(0.5) {
            let look = try OrbitPredictor.look(satellite, observer: observer, at: t)
            let beta = look.rangeRateKmS * 1000 / speedOfLightMS
            let rx: Int64
            let tx: Int64
            let mode: String
            if !transponder.isLinear {
                rx = Int64((Double(nominal.downlink) * (1 - beta) + overallCal).rounded())
                tx = nominal.uplink > 0
                    ? Int64((Double(nominal.uplink) / (1 - beta)).rounded()) : 0
                mode = "FM/independent"
            } else if hold == "uplink" {
                let uFix = Double(nominal.uplink)
                let uHeard = uFix * (1 - beta)
                let dlSatFrame = Double(nominal.downlink) + sign * (uHeard - Double(nominal.uplink))
                rx = Int64((dlSatFrame * (1 - beta) + overallCal).rounded())
                tx = nominal.uplink > 0 ? nominal.uplink : 0
                mode = "linear/hold-uplink"
            } else {
                // Park the ground RX dial; the satellite-frame downlink under it
                // drifts as dl/(1-beta), and that drift must carry into the uplink
                // leg (round-trip), else the held-downlink TX is mistuned by the
                // receive-leg Doppler. Mirrors the hold-uplink branch and CardSat.
                let dlSatFrame = Double(nominal.downlink) / (1 - beta)
                let ulSatFrame = Double(nominal.uplink) + sign * (dlSatFrame - Double(nominal.downlink))
                rx = Int64((Double(nominal.downlink) + overallCal).rounded())
                tx = nominal.uplink > 0 ? Int64((ulSatFrame / (1 - beta)).rounded()) : 0
                mode = "linear/hold-downlink"
            }
            rows.append(.init(id: t, date: t,
                              azimuthDegrees: look.azimuth,
                              elevationDegrees: look.elevation,
                              rangeRateKmS: look.rangeRateKmS,
                              receiveHz: rx, transmitHz: tx, mode: mode))
            t = t.addingTimeInterval(max(1, intervalSeconds))
        }
        return rows
    }

    static func passbandPlan(_ transponder: TransponderRecord) -> [PassbandPlanRow] {
        guard transponder.downlinkLow > 0 else { return [] }
        if !transponder.isLinear {
            return [.init(id: 0, percent: 0, downlinkHz: transponder.downlinkCenter,
                          uplinkHz: transponder.uplinkCenter)]
        }
        return stride(from: 0, through: 100, by: 10).map { percent in
            let offset = Int64((Double(transponder.bandwidth) * Double(percent) / 100.0).rounded())
            let pair = OrbitPredictor.passbandFrequencies(transponder, offsetHz: offset)
            return PassbandPlanRow(id: percent, percent: percent,
                                   downlinkHz: pair.downlink, uplinkHz: pair.uplink)
        }
    }

    private static func state(_ satellite: Satellite, at date: Date) throws -> (position: Vector, velocity: Vector) {
        (try satellite.position(julianDays: date.julianDate),
         try satellite.velocity(julianDays: date.julianDate))
    }

    private static func magnitude(_ v: Vector) -> Double {
        sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    }

    private static func separation(_ a: Vector, _ b: Vector) -> Double {
        let x = a.x - b.x, y = a.y - b.y, z = a.z - b.z
        return sqrt(x * x + y * y + z * z)
    }
}
