import Foundation
import SatelliteKit


struct WorkableSetSnapshot: Sendable {
    let grids: [String]
    let states: [String]
    let dxcc: [String]
}

struct WorkableHorizonSnapshot: Sendable {
    let states: [String]
    let dxcc: [String]
    let grids: [String]
    let satelliteCount: Int
    let passCount: Int
}

struct PlanningSearchHit: Identifiable, Sendable {
    let id: String
    let satelliteName: String
    let norad: UInt
    let start: Date
    let end: Date
    let maxElevation: Double
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct RovePassRecord: Identifiable, Sendable {
    let id: String
    let satelliteName: String
    let norad: UInt
    let aos: Date
    let los: Date
    let maxElevation: Double
    let grids: [String]
    let states: [String]
    let dxcc: [String]
}

struct SatelliteLOSWindow: Identifiable, Sendable {
    let id: Date
    let start: Date
    let end: Date
    var minRangeKm: Double = 0
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct VisiblePassRecord: Identifiable, Sendable {
    let id: Date
    let pass: PredictedPass
    let bestEstimatedMagnitude: Double
    let bestSunElevation: Double
    let bestSatelliteElevation: Double
}

struct HorizonMask: Sendable {
    var north: Double = 0
    var east: Double = 0
    var south: Double = 0
    var west: Double = 0

    func elevation(at azimuth: Double) -> Double {
        let a = ((azimuth.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let anchors = [(0.0, north), (90.0, east), (180.0, south), (270.0, west), (360.0, north)]
        for i in 0..<(anchors.count - 1) where a >= anchors[i].0 && a <= anchors[i + 1].0 {
            let span = anchors[i + 1].0 - anchors[i].0
            let f = span > 0 ? (a - anchors[i].0) / span : 0
            return anchors[i].1 + f * (anchors[i + 1].1 - anchors[i].1)
        }
        return north
    }
}

enum ParityPlanningEngine {
    static let stateCentroids: [String: LatLon] = [
        "AL": .init(latitude:32.8, longitude:-86.8), "AK": .init(latitude:64.2, longitude:-149.5),
        "AZ": .init(latitude:34.3, longitude:-111.7), "AR": .init(latitude:34.8, longitude:-92.4),
        "CA": .init(latitude:37.2, longitude:-119.3), "CO": .init(latitude:39.0, longitude:-105.5),
        "CT": .init(latitude:41.6, longitude:-72.7), "DE": .init(latitude:39.0, longitude:-75.5),
        "FL": .init(latitude:28.6, longitude:-82.4), "GA": .init(latitude:32.6, longitude:-83.4),
        "HI": .init(latitude:20.3, longitude:-156.4), "ID": .init(latitude:44.4, longitude:-114.6),
        "IL": .init(latitude:40.0, longitude:-89.2), "IN": .init(latitude:39.9, longitude:-86.3),
        "IA": .init(latitude:42.0, longitude:-93.5), "KS": .init(latitude:38.5, longitude:-98.4),
        "KY": .init(latitude:37.5, longitude:-85.3), "LA": .init(latitude:31.0, longitude:-92.0),
        "ME": .init(latitude:45.4, longitude:-69.2), "MD": .init(latitude:39.0, longitude:-76.8),
        "MA": .init(latitude:42.3, longitude:-71.8), "MI": .init(latitude:44.3, longitude:-85.4),
        "MN": .init(latitude:46.3, longitude:-94.3), "MS": .init(latitude:32.7, longitude:-89.7),
        "MO": .init(latitude:38.4, longitude:-92.5), "MT": .init(latitude:47.0, longitude:-109.6),
        "NE": .init(latitude:41.5, longitude:-99.8), "NV": .init(latitude:39.3, longitude:-116.6),
        "NH": .init(latitude:43.7, longitude:-71.6), "NJ": .init(latitude:40.1, longitude:-74.7),
        "NM": .init(latitude:34.4, longitude:-106.1), "NY": .init(latitude:42.9, longitude:-75.5),
        "NC": .init(latitude:35.5, longitude:-79.4), "ND": .init(latitude:47.4, longitude:-100.5),
        "OH": .init(latitude:40.3, longitude:-82.8), "OK": .init(latitude:35.6, longitude:-97.5),
        "OR": .init(latitude:44.0, longitude:-120.5), "PA": .init(latitude:40.9, longitude:-77.8),
        "RI": .init(latitude:41.7, longitude:-71.6), "SC": .init(latitude:33.9, longitude:-80.9),
        "SD": .init(latitude:44.4, longitude:-100.2), "TN": .init(latitude:35.9, longitude:-86.4),
        "TX": .init(latitude:31.5, longitude:-99.3), "UT": .init(latitude:39.3, longitude:-111.7),
        "VT": .init(latitude:44.1, longitude:-72.7), "VA": .init(latitude:37.5, longitude:-78.9),
        "WA": .init(latitude:47.4, longitude:-120.4), "WV": .init(latitude:38.6, longitude:-80.6),
        "WI": .init(latitude:44.6, longitude:-90.0), "WY": .init(latitude:43.0, longitude:-107.6)
    ]

    static func targetLocation(kind: String, value: String) -> LatLon? {
        switch kind {
        case "grid": return FeatureEngine.gridToLatLon(value)
        case "state": return stateCentroids[value.uppercased()]
        case "dxcc":
            if let exact = DXCCData.entity(named: value) { return .init(latitude: exact.latitude, longitude: exact.longitude) }
            if let first = DXCCData.search(value, limit: 1).first { return .init(latitude: first.latitude, longitude: first.longitude) }
            return nil
        default: return FeatureEngine.parseLocation(value)
        }
    }

    static func workableNow(_ satellite: SatelliteRecord, at date: Date = .now) throws -> WorkableSetSnapshot {
        let sub = try OrbitPredictor.subpoint(satellite, at: date)
        return workableSnapshot(subLatitude: sub.latitude, subLongitude: sub.longitude, altitudeKm: sub.altitudeKm)
    }

    static func workableAcrossNextPass(_ satellite: SatelliteRecord, observer: ObserverSite, minimumElevation: Double = 5, step: TimeInterval = 30) throws -> WorkableSetSnapshot {
        guard let pass = try OrbitPredictor.predictPasses(satellite, observer: observer, from: .now, minElevation: minimumElevation, maxCount: 1, horizonDays: 3).first else {
            return .init(grids: [], states: [], dxcc: [])
        }
        var grids = Set<String>(), states = Set<String>(), dxcc = Set<String>()
        var t = pass.aos
        while t <= pass.los {
            let sub = try OrbitPredictor.subpoint(satellite, at: t)
            let snap = workableSnapshot(subLatitude: sub.latitude, subLongitude: sub.longitude, altitudeKm: sub.altitudeKm)
            grids.formUnion(snap.grids); states.formUnion(snap.states); dxcc.formUnion(snap.dxcc)
            t = t.addingTimeInterval(step)
        }
        return .init(grids: grids.sorted(), states: states.sorted(), dxcc: dxcc.sorted())
    }

    private static func workableSnapshot(subLatitude: Double, subLongitude: Double, altitudeKm: Double) -> WorkableSetSnapshot {
        let radius = FeatureEngine.footprintRadiusDegrees(altitudeKm: altitudeKm)
        let states = stateCentroids.compactMap { code, ll in
            FeatureEngine.angularSeparationDegrees(subLatitude, subLongitude, ll.latitude, ll.longitude) <= radius ? code : nil
        }.sorted()
        let dxcc = DXCCData.workable(subLatitude: subLatitude, subLongitude: subLongitude, altitudeKm: altitudeKm).map { "\($0.prefix) \($0.name)" }.sorted()
        let grids = FeatureEngine.workableGrids(subLatitude: subLatitude, subLongitude: subLongitude, altitudeKm: altitudeKm)
        return .init(grids: grids, states: states, dxcc: dxcc)
    }

    static func workableHorizon(
        favorites: [SatelliteRecord], observer: ObserverSite, from start: Date = .now,
        days: Int = 10, minimumElevation: Double = 5, includeGrids: Bool = false,
        step: TimeInterval = 60
    ) throws -> WorkableHorizonSnapshot {
        var states = Set<String>(), dxcc = Set<String>(), grids = Set<String>()
        var passCount = 0, satCount = 0
        for satellite in favorites.prefix(25) {
            let passes = try OrbitPredictor.predictPasses(satellite, observer: observer, from: start,
                minElevation: minimumElevation, maxCount: 200, horizonDays: Double(days))
            guard !passes.isEmpty else { continue }
            satCount += 1
            passCount += passes.count
            for pass in passes {
                var t = pass.aos
                while t <= pass.los {
                    let sub = try OrbitPredictor.subpoint(satellite, at: t)
                    let radius = FeatureEngine.footprintRadiusDegrees(altitudeKm: sub.altitudeKm)
                    for (code, ll) in stateCentroids where FeatureEngine.angularSeparationDegrees(sub.latitude, sub.longitude, ll.latitude, ll.longitude) <= radius { states.insert(code) }
                    for entity in DXCCData.entities where FeatureEngine.angularSeparationDegrees(sub.latitude, sub.longitude, entity.latitude, entity.longitude) <= radius { dxcc.insert(entity.name) }
                    if includeGrids { grids.formUnion(FeatureEngine.workableGrids(subLatitude: sub.latitude, subLongitude: sub.longitude, altitudeKm: sub.altitudeKm)) }
                    t = t.addingTimeInterval(step)
                }
            }
        }
        return .init(states: states.sorted(), dxcc: dxcc.sorted(), grids: grids.sorted(), satelliteCount: satCount, passCount: passCount)
    }

    static func targetSearch(
        favorites: [SatelliteRecord], observer: ObserverSite, target: LatLon,
        from start: Date = .now, days: Int = 10, minimumElevation: Double = 5,
        step: TimeInterval = 30, maxResults: Int = 60
    ) throws -> [PlanningSearchHit] {
        var output: [PlanningSearchHit] = []
        for sat in favorites.prefix(25) {
            let passes = try OrbitPredictor.predictPasses(sat, observer: observer, from: start,
                minElevation: minimumElevation, maxCount: 200, horizonDays: Double(days))
            for pass in passes {
                var t = pass.aos
                var open: Date?, close: Date?, maxEl = -90.0
                while t <= pass.los {
                    let sub = try OrbitPredictor.subpoint(sat, at: t)
                    let radius = FeatureEngine.footprintRadiusDegrees(altitudeKm: sub.altitudeKm)
                    let hit = FeatureEngine.angularSeparationDegrees(sub.latitude, sub.longitude, target.latitude, target.longitude) <= radius
                    if hit {
                        if open == nil { open = t }
                        close = t
                        let look = try OrbitPredictor.look(sat, observer: observer, at: t)
                        maxEl = max(maxEl, look.elevation)
                    }
                    t = t.addingTimeInterval(step)
                }
                if let a = open, let b = close {
                    output.append(.init(id: "\(sat.id)-\(a.timeIntervalSince1970)", satelliteName: sat.name, norad: sat.id, start: a, end: b, maxElevation: maxEl))
                }
            }
        }
        return Array(output.sorted { $0.start < $1.start }.prefix(maxResults))
    }

    static func rovePasses(
        favorites: [SatelliteRecord], stop: ObserverSite, from start: Date = .now,
        hours: Double = 24, minimumElevation: Double = 5, step: TimeInterval = 60
    ) throws -> [RovePassRecord] {
        var out: [RovePassRecord] = []
        for sat in favorites.prefix(25) {
            let passes = try OrbitPredictor.predictPasses(sat, observer: stop, from: start,
                minElevation: minimumElevation, maxCount: 40, horizonDays: hours / 24)
            for pass in passes {
                var grids = Set<String>(), states = Set<String>(), entities = Set<String>()
                var t = pass.aos
                while t <= pass.los {
                    let sub = try OrbitPredictor.subpoint(sat, at: t)
                    let radius = FeatureEngine.footprintRadiusDegrees(altitudeKm: sub.altitudeKm)
                    grids.formUnion(FeatureEngine.workableGrids(subLatitude: sub.latitude, subLongitude: sub.longitude, altitudeKm: sub.altitudeKm))
                    for (code, ll) in stateCentroids where FeatureEngine.angularSeparationDegrees(sub.latitude, sub.longitude, ll.latitude, ll.longitude) <= radius { states.insert(code) }
                    for entity in DXCCData.entities where FeatureEngine.angularSeparationDegrees(sub.latitude, sub.longitude, entity.latitude, entity.longitude) <= radius { entities.insert("\(entity.prefix) \(entity.name)") }
                    t = t.addingTimeInterval(step)
                }
                out.append(.init(id: "\(sat.id)-\(pass.aos.timeIntervalSince1970)", satelliteName: sat.name, norad: sat.id, aos: pass.aos, los: pass.los, maxElevation: pass.maxElevation, grids: grids.sorted(), states: states.sorted(), dxcc: entities.sorted()))
            }
        }
        return out.sorted { $0.aos < $1.aos }
    }

    static func satelliteLOSWindows(
        first: SatelliteRecord, second: SatelliteRecord, from start: Date = .now,
        hours: Double = 24, step: TimeInterval = 60
    ) throws -> [SatelliteLOSWindow] {
        let a = Satellite(elements: first.elements), b = Satellite(elements: second.elements)
        let end = start.addingTimeInterval(hours * 3600)
        var windows: [SatelliteLOSWindow] = [], open: Date?, last: Date?
        var minRange = Double.greatestFiniteMagnitude
        var t = start
        while t <= end {
            let r1 = try a.position(julianDays: t.julianDate), r2 = try b.position(julianDays: t.julianDate)
            let clear = satToSatLOS(r1, r2)
            if clear {
                if open == nil { open = t; minRange = .greatestFiniteMagnitude }
                last = t
                let range = sqrt(pow(r1.x - r2.x, 2) + pow(r1.y - r2.y, 2) + pow(r1.z - r2.z, 2))
                minRange = min(minRange, range)
            } else if let s = open, let e = last {
                windows.append(.init(id: s, start: s, end: e, minRangeKm: minRange))
                open = nil; last = nil; minRange = .greatestFiniteMagnitude
            }
            t = t.addingTimeInterval(step)
        }
        if let s = open, let e = last { windows.append(.init(id: s, start: s, end: e, minRangeKm: minRange)) }
        return windows
    }

    static func visiblePasses(
        satellite: SatelliteRecord, observer: ObserverSite, from start: Date = .now,
        days: Double = 7, minimumElevation: Double = 5
    ) throws -> [VisiblePassRecord] {
        let passes = try OrbitPredictor.predictPasses(satellite, observer: observer, from: start,
            minElevation: minimumElevation, maxCount: 100, horizonDays: days)
        var out: [VisiblePassRecord] = []
        for pass in passes {
            var t = pass.aos, bestMag = 99.0, bestSun = 90.0, bestEl = -90.0, visible = false
            while t <= pass.los {
                let look = try OrbitPredictor.look(satellite, observer: observer, at: t)
                let sunEl = FeatureEngine.sunMoon(site: observer, at: t).sunElevation
                if look.sunlit && sunEl <= -6 && look.elevation >= 10 {
                    visible = true
                    bestSun = min(bestSun, sunEl); bestEl = max(bestEl, look.elevation)
                    let mag = 6.0 + 5 * log10(max(0.1, look.rangeKm / 1000.0))
                    bestMag = min(bestMag, mag)
                }
                t = t.addingTimeInterval(30)
            }
            if visible { out.append(.init(id: pass.aos, pass: pass, bestEstimatedMagnitude: bestMag, bestSunElevation: bestSun, bestSatelliteElevation: bestEl)) }
        }
        return out
    }

    static func trim(_ pass: PredictedPass, satellite: SatelliteRecord, observer: ObserverSite, mask: HorizonMask, step: TimeInterval = 10) throws -> (Date, Date)? {
        var t = pass.aos, first: Date?, last: Date?
        while t <= pass.los {
            let look = try OrbitPredictor.look(satellite, observer: observer, at: t)
            if look.elevation >= mask.elevation(at: look.azimuth) { if first == nil { first = t }; last = t }
            t = t.addingTimeInterval(step)
        }
        if let first, let last { return (first, last) }
        return nil
    }

    private static func satToSatLOS(_ r1: Vector, _ r2: Vector) -> Bool {
        let dx = r2.x-r1.x, dy = r2.y-r1.y, dz = r2.z-r1.z
        let dd = dx*dx+dy*dy+dz*dz
        if dd == 0 { return true }
        let t = -(r1.x*dx+r1.y*dy+r1.z*dz)/dd
        if t <= 0 || t >= 1 { return true }
        let x=r1.x+t*dx, y=r1.y+t*dy, z=r1.z+t*dz
        return sqrt(x*x+y*y+z*z) > FeatureEngine.earthRadiusKm
    }
}
