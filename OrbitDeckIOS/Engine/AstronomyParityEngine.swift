import Foundation
import SatelliteKit

struct AuroraOutlookRecord: Sendable {
    let magneticLatitude: Double
    let kp: Double?
    let boundaryLatitude: Double?
    let marginDegrees: Double?
    let visual: String
    let radio: String
}

struct OccultationRecord: Identifiable, Sendable {
    let id: String
    let target: String
    let kind: String
    let time: Date
    let separationDegrees: Double
    let lunarSemidiameterDegrees: Double
    let moonElevation: Double
    let occultation: Bool
    let ingress: Date?
    let egress: Date?
}

struct AppulseRecord: Identifiable, Sendable {
    let id: String
    let first: String
    let second: String
    let time: Date
    let separationDegrees: Double
}

struct EclipseEventRecord: Identifiable, Sendable {
    let id: String
    let kind: String
    let className: String
    let maxTime: Date
    let magnitude: Double
    let elevation: Double
    let visible: Bool
    let contactStart: Date?
    let contactEnd: Date?
    let centralStart: Date?
    let centralEnd: Date?
    let minimumSeparationDegrees: Double
}

struct EclipseGroundTrackPoint: Identifiable, Sendable {
    let id: Date
    let time: Date
    let latitude: Double
    let longitude: Double
}

enum AstronomyParityEngine {
    private struct OccultationHit {
        var target: String
        var kind: String
        var time: Date
        var separation: Double
    }
    private static let d2r = Double.pi / 180
    private static let r2d = 180 / Double.pi
    private static let moonRadiusKm = 1737.4
    private static let sunRadiusKm = 696_000.0
    private static let auKm = 149_597_870.7
    private static let magneticPole = LatLon(latitude: 80.65, longitude: -72.68)

    private static let stars: [(String, Double, Double)] = [
        ("Aldebaran",68.98,16.51), ("Regulus",152.09,11.97),
        ("Spica",201.30,-11.16), ("Antares",247.35,-26.43),
        ("Pollux",116.33,28.03), ("Beta Scorpii",241.36,-19.81),
        ("Delta Scorpii",240.08,-22.62), ("Zubenelgenubi",222.72,-16.04)
    ]
    private static let planets = ["Mercury","Venus","Mars","Jupiter","Saturn"]

    static func aurora(site: ObserverSite, kp: Double?) -> AuroraOutlookRecord {
        let lat = site.latitude*d2r, lon = site.longitude*d2r
        let pl = magneticPole.latitude*d2r, po = magneticPole.longitude*d2r
        let c = sin(pl)*sin(lat)+cos(pl)*cos(lat)*cos(lon-po)
        let magneticLatitude = asin(max(-1,min(1,c)))*r2d
        guard let kp else {
            return .init(magneticLatitude: magneticLatitude, kp: nil, boundaryLatitude: nil,
                         marginDegrees: nil, visual: "No Kp available", radio: "No Kp available")
        }
        let boundary = 66.5 - 2*kp
        let margin = abs(magneticLatitude)-boundary
        let visual: String
        if margin >= 3 { visual = "Likely overhead" }
        else if margin >= 0 { visual = "Likely on the poleward horizon" }
        else if margin >= -5 { visual = "Possible low on the horizon under a strong substorm" }
        else { visual = "Unlikely at this latitude" }
        let radio = margin >= -8 ? "Auroral scatter likely on 6 m and 2 m" : "Auroral scatter unlikely"
        return .init(magneticLatitude: magneticLatitude, kp: kp, boundaryLatitude: boundary,
                     marginDegrees: margin, visual: visual, radio: radio)
    }

    static func occultations(site: ObserverSite, from start: Date = .now,
                             days: Int = 365, coarseStepHours: Double = 3) -> [OccultationRecord] {
        var hits: [OccultationHit] = []
        let steps = max(1, Int(Double(days)*24/coarseStepHours))
        for i in 0...steps {
            let date = start.addingTimeInterval(Double(i)*coarseStepHours*3600)
            let moon = moonRaDec(date)
            let sd = moonSemidiameter(date)
            for star in stars {
                let sep = angularSeparation(ra1: moon.ra, dec1: moon.dec, ra2: star.1, dec2: star.2)
                if sep < sd + 1 { hits.append(.init(target:star.0,kind:"star",time:date,separation:sep)) }
            }
            for planet in planets {
                guard let p = FeatureEngine.planetRaDec(name: planet, date: date) else { continue }
                let sep = angularSeparation(ra1: moon.ra, dec1: moon.dec, ra2:p.ra, dec2:p.dec)
                if sep < sd + 1 { hits.append(.init(target:planet,kind:"planet",time:date,separation:sep)) }
            }
        }
        var coarse: [OccultationHit] = []
        for hit in hits.sorted(by:{$0.time<$1.time}) {
            if let lastIndex = coarse.indices.last,
               coarse[lastIndex].target == hit.target,
               hit.time.timeIntervalSince(coarse[lastIndex].time) < 12*3600 {
                if hit.separation < coarse[lastIndex].separation { coarse[lastIndex] = hit }
            } else { coarse.append(hit) }
        }
        var output: [OccultationRecord] = []
        for hit in coarse {
            guard let best = refineOccultation(hit, site:site, halfWindow:coarseStepHours*3600) else { continue }
            if best.occultation || best.separationDegrees < 1 { output.append(best) }
        }
        return output.sorted{$0.time<$1.time}
    }

    static func appulses(from start: Date = .now, days: Int = 365,
                         coarseStepHours: Double = 12, maxSeparation: Double = 2) -> [AppulseRecord] {
        let names = planets + ["Moon"]
        var pairs: [(String,String)] = []
        for i in names.indices { for j in names.indices where j > i { pairs.append((names[i],names[j])) } }
        struct Candidate { var first:String; var second:String; var time:Date; var sep:Double }
        var candidates: [Candidate] = []
        let steps = max(1,Int(Double(days)*24/coarseStepHours))
        for i in 0...steps {
            let date = start.addingTimeInterval(Double(i)*coarseStepHours*3600)
            var positions: [String:(Double,Double)] = [:]
            for planet in planets { if let p=FeatureEngine.planetRaDec(name:planet,date:date){positions[planet]=(p.ra,p.dec)} }
            let m=moonRaDec(date); positions["Moon"]=(m.ra,m.dec)
            for pair in pairs {
                guard let a=positions[pair.0],let b=positions[pair.1] else{continue}
                let sep=angularSeparation(ra1:a.0,dec1:a.1,ra2:b.0,dec2:b.1)
                if sep < maxSeparation { candidates.append(.init(first:pair.0,second:pair.1,time:date,sep:sep)) }
            }
        }
        var clustered: [Candidate] = []
        for c in candidates.sorted(by:{$0.time<$1.time}) {
            if let idx=clustered.lastIndex(where:{$0.first==c.first && $0.second==c.second && c.time.timeIntervalSince($0.time)<20*86400}) {
                if c.sep < clustered[idx].sep { clustered[idx]=c }
            } else { clustered.append(c) }
        }
        return clustered.map { c in
            let best=refineAppulse(first:c.first,second:c.second,near:c.time)
            return .init(id:"\(c.first)-\(c.second)-\(Int(best.0.timeIntervalSince1970))",first:c.first,second:c.second,time:best.0,separationDegrees:best.1)
        }.sorted{$0.time<$1.time}
    }

    static func eclipses(site: ObserverSite, from start: Date = .now, days: Int = 730) -> [EclipseEventRecord] {
        // Find new/full-Moon minima in a 6-hour scan, then refine to two-minute planning precision.
        let step: TimeInterval = 6*3600
        let end=start.addingTimeInterval(Double(days)*86400)
        var samples:[(Date,Double)] = []
        var t=start
        while t<=end { samples.append((t,sunMoonSeparation(t))); t=t.addingTimeInterval(step) }
        var candidates:[(Date,Bool)] = [] // Bool new-moon side
        if samples.count>=3 {
            for i in 1..<(samples.count-1) {
                let sep=samples[i].1
                let prev=samples[i-1].1,next=samples[i+1].1
                if sep<=prev && sep<=next && sep<6 { candidates.append((samples[i].0,true)) }
                let full=abs(180-sep),pfull=abs(180-prev),nfull=abs(180-next)
                if full<=pfull && full<=nfull && full<6 { candidates.append((samples[i].0,false)) }
            }
        }
        var out:[EclipseEventRecord]=[]
        for candidate in candidates {
            if candidate.1, let e=solarEclipse(site:site,near:candidate.0){out.append(e)}
            if !candidate.1, let e=lunarEclipse(site:site,near:candidate.0){out.append(e)}
        }
        var dedup:[EclipseEventRecord]=[]
        for event in out.sorted(by:{$0.maxTime<$1.maxTime}) {
            if let last=dedup.last, last.kind==event.kind && event.maxTime.timeIntervalSince(last.maxTime)<2*86400 { continue }
            dedup.append(event)
        }
        return dedup
    }

    static func eclipseGroundTrack(_ event: EclipseEventRecord, spanHours: Double = 4, stepMinutes: Double = 5) -> [EclipseGroundTrackPoint] {
        guard event.kind.lowercased() == "solar" else { return [] }
        let half = max(0.5, spanHours) * 3600 / 2
        let step = max(60, stepMinutes * 60)
        var t = event.maxTime.addingTimeInterval(-half)
        let end = event.maxTime.addingTimeInterval(half)
        var out: [EclipseGroundTrackPoint] = []
        while t <= end {
            let jd = t.julianDate
            let moon = FeatureEngine.moonSolution(jd)
            let mu = moon.vector
            let md = moon.distanceKm
            let mx = mu.x * md, my = mu.y * md, mz = mu.z * md
            let sun = FeatureEngine.sunECIUnit(jd).vector
            let dx = -sun.x, dy = -sun.y, dz = -sun.z
            let b = mx*dx + my*dy + mz*dz
            let c = mx*mx + my*my + mz*mz - FeatureEngine.earthRadiusKm*FeatureEngine.earthRadiusKm
            let disc = b*b - c
            if disc >= 0 {
                let root = sqrt(disc)
                let candidates = [-b-root, -b+root].filter { $0 > 0 }.sorted()
                if let distance = candidates.first {
                    let x = mx + distance*dx, y = my + distance*dy, z = mz + distance*dz
                    let latitude = atan2(z, hypot(x,y))*r2d
                    var longitude = atan2(y,x)*r2d - FeatureEngine.gmstRadians(jd)*r2d
                    longitude = ((longitude + 540).truncatingRemainder(dividingBy: 360)) - 180
                    out.append(.init(id:t,time:t,latitude:latitude,longitude:longitude))
                }
            }
            t = t.addingTimeInterval(step)
        }
        return out
    }

    private static func refineOccultation(_ hit: OccultationHit, site:ObserverSite, halfWindow:TimeInterval) -> OccultationRecord? {
        var bestDate=hit.time,bestSep=Double.greatestFiniteMagnitude
        var t=hit.time.addingTimeInterval(-max(3600,halfWindow))
        let end=hit.time.addingTimeInterval(max(3600,halfWindow))
        while t<=end {
            let m=moonRaDec(t)
            let target:(Double,Double)?
            if hit.kind=="star",let row=stars.first(where:{$0.0==hit.target}){target=(row.1,row.2)}
            else if let p=FeatureEngine.planetRaDec(name:hit.target,date:t){target=(p.ra,p.dec)} else {target=nil}
            if let target {
                let sep=angularSeparation(ra1:m.ra,dec1:m.dec,ra2:target.0,dec2:target.1)
                if sep<bestSep {bestSep=sep;bestDate=t}
            }
            t=t.addingTimeInterval(120)
        }
        let moonEl=FeatureEngine.sunMoon(site:site,at:bestDate).moonElevation
        guard moonEl>0 else{return nil}
        let sd=moonSemidiameter(bestDate)
        let isOccultation = bestSep < sd
        let contacts: (Date?, Date?)
        if isOccultation {
            contacts = intervalWhereNonpositive(center: bestDate, span: 4*3600, step: 60) { date in
                let m = moonRaDec(date)
                let target: (Double,Double)?
                if hit.kind == "star", let row = stars.first(where: { $0.0 == hit.target }) { target = (row.1,row.2) }
                else if let q = FeatureEngine.planetRaDec(name: hit.target, date: date) { target = (q.ra,q.dec) }
                else { target = nil }
                guard let target else { return 99 }
                return angularSeparation(ra1:m.ra,dec1:m.dec,ra2:target.0,dec2:target.1) - moonSemidiameter(date)
            }
        } else { contacts = (nil,nil) }
        return .init(id:"\(hit.target)-\(Int(bestDate.timeIntervalSince1970))",target:hit.target,kind:hit.kind,time:bestDate,separationDegrees:bestSep,lunarSemidiameterDegrees:sd,moonElevation:moonEl,occultation:isOccultation,ingress:contacts.0,egress:contacts.1)
    }

    private static func refineAppulse(first:String,second:String,near:Date)->(Date,Double){
        var best=near,bestSep=Double.greatestFiniteMagnitude,t=near.addingTimeInterval(-12*3600),end=near.addingTimeInterval(12*3600)
        while t<=end {
            if let a=bodyRaDec(first,t),let b=bodyRaDec(second,t) {
                let sep=angularSeparation(ra1:a.0,dec1:a.1,ra2:b.0,dec2:b.1)
                if sep<bestSep{bestSep=sep;best=t}
            }
            t=t.addingTimeInterval(300)
        }
        return(best,bestSep)
    }

    private static func bodyRaDec(_ name:String,_ date:Date)->(Double,Double)?{
        if name=="Moon" {let m=moonRaDec(date);return(m.ra,m.dec)}
        if let p=FeatureEngine.planetRaDec(name:name,date:date){return(p.ra,p.dec)}
        return nil
    }

    private static func solarEclipse(site:ObserverSite,near:Date)->EclipseEventRecord?{
        var best=near,bestSep=Double.greatestFiniteMagnitude,t=near.addingTimeInterval(-10*3600),end=near.addingTimeInterval(10*3600)
        while t<=end {let sep=sunMoonSeparation(t);if sep<bestSep{bestSep=sep;best=t};t=t.addingTimeInterval(120)}
        let moonR=moonSemidiameter(best), sunR=sunSemidiameter(best)
        guard bestSep < moonR+sunR else{return nil}
        let className:String
        if bestSep <= abs(moonR-sunR) { className = moonR>=sunR ? "total":"annular" } else { className="partial" }
        let magnitude=max(0,min(2,(moonR+sunR-bestSep)/(2*sunR)))
        let el=FeatureEngine.sunMoon(site:site,at:best).sunElevation
        let outer = intervalWhereNonpositive(center: best, span: 8*3600, step: 120) { date in
            sunMoonSeparation(date) - (moonSemidiameter(date) + sunSemidiameter(date))
        }
        let inner: (Date?,Date?)
        if className == "total" || className == "annular" {
            inner = intervalWhereNonpositive(center: best, span: 4*3600, step: 60) { date in
                sunMoonSeparation(date) - abs(moonSemidiameter(date) - sunSemidiameter(date))
            }
        } else { inner = (nil,nil) }
        return .init(id:"solar-\(Int(best.timeIntervalSince1970))",kind:"solar",className:className,maxTime:best,magnitude:magnitude,elevation:el,visible:el>0,contactStart:outer.0,contactEnd:outer.1,centralStart:inner.0,centralEnd:inner.1,minimumSeparationDegrees:bestSep)
    }

    private static func lunarEclipse(site:ObserverSite,near:Date)->EclipseEventRecord?{
        var best=near,bestSep=Double.greatestFiniteMagnitude,t=near.addingTimeInterval(-10*3600),end=near.addingTimeInterval(10*3600)
        while t<=end {let sep=abs(180-sunMoonSeparation(t));if sep<bestSep{bestSep=sep;best=t};t=t.addingTimeInterval(120)}
        let dist=FeatureEngine.sunMoon(site:site,at:best).moonDistanceKm
        let moonR=asin(min(1,moonRadiusKm/dist))*r2d
        let sunDistance=auKm
        let umbraKm=max(0,FeatureEngine.earthRadiusKm - dist*(sunRadiusKm-FeatureEngine.earthRadiusKm)/sunDistance)*1.02
        let penumbraKm=FeatureEngine.earthRadiusKm + dist*(sunRadiusKm+FeatureEngine.earthRadiusKm)/sunDistance
        let umbra=atan2(umbraKm,dist)*r2d,penumbra=atan2(penumbraKm,dist)*r2d
        guard bestSep < penumbra+moonR else{return nil}
        let className:String,magnitude:Double
        if bestSep+moonR<=umbra {className="total";magnitude=(umbra+moonR-bestSep)/(2*moonR)}
        else if bestSep<umbra+moonR {className="partial";magnitude=(umbra+moonR-bestSep)/(2*moonR)}
        else {className="penumbral";magnitude=(penumbra+moonR-bestSep)/(2*moonR)}
        let el=FeatureEngine.sunMoon(site:site,at:best).moonElevation
        let outer = intervalWhereNonpositive(center: best, span: 8*3600, step: 120) { date in
            let m = lunarShadowGeometry(date)
            let threshold = className == "penumbral" ? m.penumbra + m.moonRadius : m.umbra + m.moonRadius
            return m.separation - threshold
        }
        let central: (Date?,Date?)
        if className == "total" {
            central = intervalWhereNonpositive(center: best, span: 5*3600, step: 60) { date in
                let m = lunarShadowGeometry(date)
                return m.separation + m.moonRadius - m.umbra
            }
        } else { central = (nil,nil) }
        return .init(id:"lunar-\(Int(best.timeIntervalSince1970))",kind:"lunar",className:className,maxTime:best,magnitude:max(0,magnitude),elevation:el,visible:el>0,contactStart:outer.0,contactEnd:outer.1,centralStart:central.0,centralEnd:central.1,minimumSeparationDegrees:bestSep)
    }

    private static func lunarShadowGeometry(_ date: Date) -> (separation: Double, moonRadius: Double, umbra: Double, penumbra: Double) {
        let sep = abs(180 - sunMoonSeparation(date))
        let dist = FeatureEngine.moonSolution(date.julianDate).distanceKm
        let moonR = asin(min(1, moonRadiusKm/dist))*r2d
        let umbraKm=max(0,FeatureEngine.earthRadiusKm - dist*(sunRadiusKm-FeatureEngine.earthRadiusKm)/auKm)*1.02
        let penumbraKm=FeatureEngine.earthRadiusKm + dist*(sunRadiusKm+FeatureEngine.earthRadiusKm)/auKm
        return (sep, moonR, atan2(umbraKm,dist)*r2d, atan2(penumbraKm,dist)*r2d)
    }

    private static func intervalWhereNonpositive(center: Date, span: TimeInterval, step: TimeInterval, metric: (Date) -> Double) -> (Date?, Date?) {
        let start = center.addingTimeInterval(-span/2), end = center.addingTimeInterval(span/2)
        var samples: [(Date,Double)] = [], t = start
        while t <= end { samples.append((t,metric(t))); t = t.addingTimeInterval(max(10,step)) }
        guard let firstInside = samples.firstIndex(where: { $0.1 <= 0 }),
              let lastInside = samples.lastIndex(where: { $0.1 <= 0 }) else { return (nil,nil) }
        func refine(_ outside: Date, _ inside: Date) -> Date {
            var a=outside,b=inside,fa=metric(outside)
            for _ in 0..<18 {
                let mid=Date(timeIntervalSince1970:(a.timeIntervalSince1970+b.timeIntervalSince1970)/2),fm=metric(mid)
                if (fa > 0) == (fm > 0) { a=mid;fa=fm } else { b=mid }
            }
            return Date(timeIntervalSince1970:(a.timeIntervalSince1970+b.timeIntervalSince1970)/2)
        }
        let a: Date
        if firstInside > 0 { a = refine(samples[firstInside-1].0, samples[firstInside].0) } else { a = samples[firstInside].0 }
        let b: Date
        if lastInside + 1 < samples.count { b = refine(samples[lastInside+1].0, samples[lastInside].0) } else { b = samples[lastInside].0 }
        return (a,b)
    }

    private static func moonRaDec(_ date:Date)->(ra:Double,dec:Double){
        let v=FeatureEngine.moonSolution(date.julianDate).vector
        return(FeatureEngine.normalizedDegrees(atan2(v.y,v.x)*r2d),asin(max(-1,min(1,v.z)))*r2d)
    }
    private static func sunRaDec(_ date:Date)->(ra:Double,dec:Double){
        let v=FeatureEngine.sunECIUnit(date.julianDate).vector
        return(FeatureEngine.normalizedDegrees(atan2(v.y,v.x)*r2d),asin(max(-1,min(1,v.z)))*r2d)
    }
    private static func moonSemidiameter(_ date:Date)->Double{let d=FeatureEngine.moonSolution(date.julianDate).distanceKm;return asin(min(1,moonRadiusKm/d))*r2d}
    private static func sunSemidiameter(_ date:Date)->Double{0.2666}
    private static func sunMoonSeparation(_ date:Date)->Double{let a=sunRaDec(date),b=moonRaDec(date);return angularSeparation(ra1:a.ra,dec1:a.dec,ra2:b.ra,dec2:b.dec)}
    private static func angularSeparation(ra1:Double,dec1:Double,ra2:Double,dec2:Double)->Double{
        let a=dec1*d2r,b=dec2*d2r,dr=(ra2-ra1)*d2r
        return acos(max(-1,min(1,sin(a)*sin(b)+cos(a)*cos(b)*cos(dr))))*r2d
    }
}
