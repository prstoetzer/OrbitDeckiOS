import Foundation
import SatelliteKit

enum OrbitPredictorError: LocalizedError {
    case propagation(String)

    var errorDescription: String? {
        switch self {
        case .propagation(let message): "Propagation failed: \(message)"
        }
    }
}

struct NextEvent: Sendable {
    let isVisible: Bool
    let date: Date
    let maxElevation: Double?
}

enum OrbitPredictor {
    static let earthRadiusKm = 6378.135
    static let earthRotationRadS = 7.2921150e-5
    static let speedOfLightMS = 299_792_458.0

    static func look(_ record: SatelliteRecord, observer: ObserverSite, at date: Date = .now) throws -> LiveLook {
        let satellite = Satellite(elements: record.elements)
        let jd = date.julianDate

        do {
            let r = try satellite.position(julianDays: jd)
            let v = try satellite.velocity(julianDays: jd)
            let geo = eci2geo(julianDays: jd, celestial: r)
            let top = try satellite.topPosition(julianDays: jd, observer: observer.satelliteKitLocation)
            let rr = rangeRate(position: r, velocity: v, observer: observer, julianDay: jd)
            let sunlit = isSunlit(position: r, julianDay: jd)
            let beta = betaAngle(record: record, julianDay: jd)
            return LiveLook(
                date: date,
                azimuth: normalizedDegrees(top.azim),
                elevation: top.elev,
                rangeKm: top.dist,
                rangeRateKmS: rr,
                subLatitude: geo.lat,
                subLongitude: normalizedLongitude(geo.lon),
                altitudeKm: geo.alt,
                sunlit: sunlit,
                betaAngleDeg: beta,
                footprintRadiusKm: footprintRadius(altitudeKm: geo.alt)
            )
        } catch {
            throw OrbitPredictorError.propagation(error.localizedDescription)
        }
    }

    /// Lightweight illumination-only propagation used by report rasters.
    /// This deliberately avoids topocentric observer work because sunlight is
    /// a satellite/Earth/Sun geometry question, not a station-relative one.
    static func sunlit(_ record: SatelliteRecord, at date: Date = .now) throws -> Bool {
        let satellite = Satellite(elements: record.elements)
        do {
            let position = try satellite.position(julianDays: date.julianDate)
            return isSunlit(position: position, julianDay: date.julianDate)
        } catch {
            throw OrbitPredictorError.propagation(error.localizedDescription)
        }
    }

    static func predictPasses(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        from start: Date = .now,
        minElevation: Double,
        maxCount: Int = 20,
        horizonDays: Double = 10,
        coarseStep: TimeInterval = 30
    ) throws -> [PredictedPass] {
        let satellite = Satellite(elements: record.elements)
        let end = start.addingTimeInterval(horizonDays * 86400)
        var output: [PredictedPass] = []
        var t = start
        var previousElevation = try elevation(satellite, observer, t)

        // In-progress pass: the satellite is already above the horizon at `start`.
        // The plain rise-scan below only fires on a below→above transition, so it
        // would silently drop the current pass (and never report a GEO/high-orbit
        // bird that is up the whole window).
        if previousElevation >= 0 {
            // Cheap continuity probe (30-min steps): is it up for the entire window?
            var continuous = true
            var probe = start
            while probe < end {
                probe = min(end, probe.addingTimeInterval(1800))
                if try elevation(satellite, observer, probe) < 0 { continuous = false; break }
                if probe == end { break }
            }
            if continuous {
                // Continuously visible (e.g. a geostationary bird above the horizon):
                // report one horizon-long visibility window.
                let tcaEnd = min(end, start.addingTimeInterval(3600))
                let tca = try refineTCA(satellite, observer, start, tcaEnd)
                let maxEl = try elevation(satellite, observer, tca)
                if maxEl >= minElevation {
                    output.append(PredictedPass(
                        id: start, aos: start, los: end, tca: tca, maxElevation: maxEl,
                        aosAzimuth: try azimuth(satellite, observer, start),
                        losAzimuth: try azimuth(satellite, observer, end)))
                }
                return output
            }
            // Sets within the window: emit the in-progress pass, then continue.
            if let pass = try buildPass(satellite, observer, start, end) {
                if pass.maxElevation >= minElevation { output.append(pass) }
                t = pass.los.addingTimeInterval(coarseStep)
                previousElevation = try elevation(satellite, observer, t)
            }
        }

        while t < end && output.count < maxCount {
            let t2 = t.addingTimeInterval(coarseStep)
            let el2 = try elevation(satellite, observer, t2)
            if previousElevation < 0, el2 >= 0 {
                let aos = try bisectRise(satellite, observer, t, t2)
                if let pass = try buildPass(satellite, observer, aos, end),
                   pass.maxElevation >= minElevation {
                    output.append(pass)
                    t = pass.los.addingTimeInterval(coarseStep)
                    previousElevation = try elevation(satellite, observer, t)
                    continue
                }
            }
            previousElevation = el2
            t = t2
        }
        return output
    }

    static func skyPath(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        pass: PredictedPass,
        step: TimeInterval = 20
    ) throws -> [SkyPoint] {
        let satellite = Satellite(elements: record.elements)
        var points: [SkyPoint] = []
        var t = pass.aos
        while t <= pass.los {
            let top = try satellite.topPosition(julianDays: t.julianDate, observer: observer.satelliteKitLocation)
            points.append(SkyPoint(id: t, date: t, azimuth: normalizedDegrees(top.azim), elevation: top.elev))
            t = t.addingTimeInterval(step)
        }
        if points.last?.date != pass.los {
            let top = try satellite.topPosition(julianDays: pass.los.julianDate, observer: observer.satelliteKitLocation)
            points.append(SkyPoint(id: pass.los, date: pass.los, azimuth: normalizedDegrees(top.azim), elevation: top.elev))
        }
        return points
    }


    /// The next horizon-crossing event relative to `from`: if the satellite is
    /// currently up, the upcoming LOS; otherwise the next AOS (with its max elevation).
    static func nextEvent(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        from: Date = .now,
        horizonDays: Double = 10
    ) throws -> NextEvent? {
        let satellite = Satellite(elements: record.elements)
        let elevationNow = try elevation(satellite, observer, from)
        if elevationNow >= 0 {
            var t = from
            var previous = elevationNow
            let end = from.addingTimeInterval(horizonDays * 86400)
            while t < end {
                let t2 = t.addingTimeInterval(20)
                let el2 = try elevation(satellite, observer, t2)
                if previous >= 0, el2 < 0 {
                    return NextEvent(isVisible: true, date: try bisectSet(satellite, observer, t, t2), maxElevation: nil)
                }
                previous = el2
                t = t2
            }
            return nil
        }
        let passes = try predictPasses(record, observer: observer, from: from, minElevation: 0, maxCount: 1, horizonDays: horizonDays)
        guard let pass = passes.first else { return nil }
        return NextEvent(isVisible: false, date: pass.aos, maxElevation: pass.maxElevation)
    }

    /// The pass in progress right now (if the satellite is above the horizon)
    /// or the next pass otherwise. Ignores the display minimum-elevation filter
    /// so a track always has an arc to show.
    static func currentOrNextPass(
        _ record: SatelliteRecord,
        observer: ObserverSite,
        from: Date = .now,
        horizonDays: Double = 10
    ) throws -> PredictedPass? {
        let satellite = Satellite(elements: record.elements)
        let horizonEnd = from.addingTimeInterval(horizonDays * 86400)
        let elevationNow = try elevation(satellite, observer, from)
        if elevationNow >= 0 {
            // Walk backward to find this pass's AOS, then build the full pass.
            var t = from
            var previous = elevationNow
            let backLimit = from.addingTimeInterval(-12 * 3600)
            while t > backLimit {
                let t2 = t.addingTimeInterval(-20)
                let el2 = try elevation(satellite, observer, t2)
                if el2 < 0, previous >= 0 {
                    let aos = try bisectRise(satellite, observer, t2, t)
                    return try buildPass(satellite, observer, aos, horizonEnd)
                }
                previous = el2
                t = t2
            }
            return try buildPass(satellite, observer, from, horizonEnd)
        }
        return try predictPasses(record, observer: observer, from: from, minElevation: 0, maxCount: 1, horizonDays: horizonDays).first
    }

    static func subpoint(_ record: SatelliteRecord, at date: Date = .now) throws -> (latitude: Double, longitude: Double, altitudeKm: Double) {
        let satellite = Satellite(elements: record.elements)
        let geo = try satellite.geoPosition(julianDays: date.julianDate)
        return (geo.lat, normalizedLongitude(geo.lon), geo.alt)
    }

    static func equatorCrossings(
        _ record: SatelliteRecord,
        from start: Date,
        to end: Date,
        ascending: Bool,
        step: TimeInterval = 60
    ) throws -> [(Date, Double)] {
        guard end > start else { return [] }
        // Derive crossings from the same ground-track sampling that the map uses
        // (one Satellite instance, sampled strictly forward), so the latitude
        // series is guaranteed to behave identically to the visible track.
        let span = end.timeIntervalSince(start)
        let center = start.addingTimeInterval(span / 2)
        let track = try groundTrack(record, centeredAt: center, durationMinutes: span / 60, step: step)
        guard track.count > 1 else { return [] }

        var result: [(Date, Double)] = []
        for i in 1..<track.count {
            let (t0, lat0, _, _) = track[i - 1]
            let (t1, lat1, lon1, _) = track[i]
            let crossed = ascending ? (lat0 < 0 && lat1 >= 0) : (lat0 > 0 && lat1 <= 0)
            if crossed {
                // Interpolate the exact crossing instant between the two samples.
                let frac = lat1 == lat0 ? 0.5 : (0 - lat0) / (lat1 - lat0)
                let crossDate = t0.addingTimeInterval(t1.timeIntervalSince(t0) * frac)
                result.append((crossDate, lon1))
            }
        }
        return result
    }

    static func groundTrack(
        _ record: SatelliteRecord,
        centeredAt date: Date = .now,
        durationMinutes: Double? = nil,
        step: TimeInterval = 60
    ) throws -> [(Date, Double, Double, Double)] {
        let satellite = Satellite(elements: record.elements)
        let duration = (durationMinutes ?? max(90, record.periodMinutes * 2.0)) * 60
        let start = date.addingTimeInterval(-duration / 2)
        let end = date.addingTimeInterval(duration / 2)
        var result: [(Date, Double, Double, Double)] = []
        var t = start
        while t <= end {
            let geo = try satellite.geoPosition(julianDays: t.julianDate)
            result.append((t, geo.lat, normalizedLongitude(geo.lon), geo.alt))
            t = t.addingTimeInterval(step)
        }
        return result
    }

    static func dopplerFrequencies(
        downlinkHz: Int64,
        uplinkHz: Int64,
        rangeRateKmS: Double,
        downlinkCalibrationHz: Double = 0,
        uplinkCalibrationHz: Double = 0
    ) -> (rx: Int64, tx: Int64) {
        let beta = (rangeRateKmS * 1000.0) / speedOfLightMS
        let rx = Double(downlinkHz) * (1.0 - beta) + downlinkCalibrationHz
        let tx = uplinkHz > 0
            ? Double(uplinkHz) / (1.0 - beta) + uplinkCalibrationHz
            : 0
        return (Int64(rx.rounded()), Int64(tx.rounded()))
    }

    static func passbandFrequencies(
        _ transponder: TransponderRecord,
        offsetHz: Int64
    ) -> (downlink: Int64, uplink: Int64) {
        guard transponder.isLinear, transponder.bandwidth > 0 else {
            return (transponder.downlinkLow, transponder.uplinkLow)
        }
        let offset = max(0, min(offsetHz, transponder.bandwidth))
        let downlink = transponder.downlinkLow + offset
        guard transponder.uplinkLow > 0 else { return (downlink, 0) }
        let uplinkBandwidth = transponder.uplinkHigh > transponder.uplinkLow
            ? transponder.uplinkHigh - transponder.uplinkLow
            : transponder.bandwidth
        let uplink = transponder.invert
            ? transponder.uplinkLow + uplinkBandwidth - offset
            : transponder.uplinkLow + offset
        return (downlink, uplink)
    }

    static func footprintRadius(altitudeKm: Double) -> Double {
        let ratio = earthRadiusKm / (earthRadiusKm + max(0, altitudeKm))
        return earthRadiusKm * acos(max(-1, min(1, ratio)))
    }

    static func betaAngle(record: SatelliteRecord, julianDay: Double) -> Double {
        let sun = sunECIUnit(julianDay)
        let i = record.inclinationDeg * .pi / 180
        let o = record.raanDeg * .pi / 180
        let nx = sin(i) * sin(o)
        let ny = -sin(i) * cos(o)
        let nz = cos(i)
        let dot = max(-1, min(1, nx * sun.x + ny * sun.y + nz * sun.z))
        return asin(dot) * 180 / .pi
    }

    private static func elevation(_ satellite: Satellite, _ observer: ObserverSite, _ date: Date) throws -> Double {
        try satellite.topPosition(julianDays: date.julianDate, observer: observer.satelliteKitLocation).elev
    }

    private static func azimuth(_ satellite: Satellite, _ observer: ObserverSite, _ date: Date) throws -> Double {
        normalizedDegrees(try satellite.topPosition(julianDays: date.julianDate, observer: observer.satelliteKitLocation).azim)
    }

    private static func bisectRise(
        _ satellite: Satellite,
        _ observer: ObserverSite,
        _ low: Date,
        _ high: Date
    ) throws -> Date {
        var lo = low
        var hi = high
        for _ in 0..<40 {
            let mid = Date(timeIntervalSince1970: (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
            if try elevation(satellite, observer, mid) < 0 {
                lo = mid
            } else {
                hi = mid
            }
            if hi.timeIntervalSince(lo) < 0.5 { break }
        }
        return hi
    }

    private static func bisectSet(
        _ satellite: Satellite,
        _ observer: ObserverSite,
        _ low: Date,
        _ high: Date
    ) throws -> Date {
        var lo = low
        var hi = high
        for _ in 0..<40 {
            let mid = Date(timeIntervalSince1970: (lo.timeIntervalSince1970 + hi.timeIntervalSince1970) / 2)
            if try elevation(satellite, observer, mid) >= 0 {
                lo = mid
            } else {
                hi = mid
            }
            if hi.timeIntervalSince(lo) < 0.5 { break }
        }
        return lo
    }

    private static func buildPass(
        _ satellite: Satellite,
        _ observer: ObserverSite,
        _ aos: Date,
        _ horizonEnd: Date
    ) throws -> PredictedPass? {
        let step: TimeInterval = 20
        var t = aos
        var previousElevation = try elevation(satellite, observer, t)
        var coarseMax = previousElevation
        var coarseTCA = aos
        var los: Date?

        while t < horizonEnd.addingTimeInterval(2400) {
            let t2 = t.addingTimeInterval(step)
            let el2 = try elevation(satellite, observer, t2)
            if el2 > coarseMax {
                coarseMax = el2
                coarseTCA = t2
            }
            if previousElevation >= 0, el2 < 0 {
                los = try bisectSet(satellite, observer, t, t2)
                break
            }
            previousElevation = el2
            t = t2
        }

        guard let los else { return nil }
        let refineStart = maxDate(aos, coarseTCA.addingTimeInterval(-step))
        let refineEnd = minDate(los, coarseTCA.addingTimeInterval(step))
        let tca = try refineTCA(satellite, observer, refineStart, refineEnd)
        let maxElevation = try elevation(satellite, observer, tca)

        return PredictedPass(
            id: aos,
            aos: aos,
            los: los,
            tca: tca,
            maxElevation: maxElevation,
            aosAzimuth: try azimuth(satellite, observer, aos),
            losAzimuth: try azimuth(satellite, observer, los)
        )
    }

    private static func refineTCA(
        _ satellite: Satellite,
        _ observer: ObserverSite,
        _ start: Date,
        _ end: Date
    ) throws -> Date {
        let gr = (sqrt(5.0) - 1.0) / 2.0
        var a = start.timeIntervalSince1970
        var b = end.timeIntervalSince1970
        var c = b - gr * (b - a)
        var d = a + gr * (b - a)

        for _ in 0..<30 {
            let ec = try elevation(satellite, observer, Date(timeIntervalSince1970: c))
            let ed = try elevation(satellite, observer, Date(timeIntervalSince1970: d))
            if ec < ed { a = c } else { b = d }
            c = b - gr * (b - a)
            d = a + gr * (b - a)
            if b - a < 1 { break }
        }
        return Date(timeIntervalSince1970: (a + b) / 2)
    }

    private static func rangeRate(position r: Vector, velocity v: Vector, observer: ObserverSite, julianDay: Double) -> Double {
        let obs = geo2eci(julianDays: julianDay, geodetic: observer.satelliteKitLocation)
        let ovx = -earthRotationRadS * obs.y
        let ovy = earthRotationRadS * obs.x
        let rx = r.x - obs.x
        let ry = r.y - obs.y
        let rz = r.z - obs.z
        let vx = v.x - ovx
        let vy = v.y - ovy
        let vz = v.z
        let mag = sqrt(rx * rx + ry * ry + rz * rz)
        guard mag > 0 else { return 0 }
        return (rx * vx + ry * vy + rz * vz) / mag
    }

    static func isSunlit(position r: Vector, julianDay: Double) -> Bool {
        let sun = sunECIUnit(julianDay)
        let projection = r.x * sun.x + r.y * sun.y + r.z * sun.z
        let r2 = r.x * r.x + r.y * r.y + r.z * r.z
        let perpendicular = sqrt(max(0, r2 - projection * projection))
        return !(projection < 0 && perpendicular < earthRadiusKm)
    }

    private static func sunECIUnit(_ jd: Double) -> (x: Double, y: Double, z: Double) {
        let n = jd - 2451545.0
        let l = fmod(280.460 + 0.9856474 * n, 360.0)
        let g = fmod(357.528 + 0.9856003 * n, 360.0) * .pi / 180
        let lambda = (l + 1.915 * sin(g) + 0.020 * sin(2 * g)) * .pi / 180
        let epsilon = (23.439 - 0.0000004 * n) * .pi / 180
        return (cos(lambda), cos(epsilon) * sin(lambda), sin(epsilon) * sin(lambda))
    }

    private static func normalizedDegrees(_ value: Double) -> Double {
        let x = value.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }

    private static func normalizedLongitude(_ value: Double) -> Double {
        var x = value.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x < -180 { x += 360 }
        return x
    }

    private static func maxDate(_ a: Date, _ b: Date) -> Date { a > b ? a : b }
    private static func minDate(_ a: Date, _ b: Date) -> Date { a < b ? a : b }
}
