import Foundation

@main
struct Parity092Smoke {
    static func main() throws {
        let site = ObserverSite(name: "Home", latitude: 39.93, longitude: -74.89, altitudeMeters: 20)
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.calendar = cal
        comps.timeZone = TimeZone(secondsFromGMT: 0)
        comps.year = 2026; comps.month = 8; comps.day = 14; comps.hour = 18; comps.minute = 0
        let start = comps.date!
        let eclipses = AstronomyParityEngine.eclipses(site: site, from: start, days: 730)
        guard !eclipses.isEmpty else { fatalError("no eclipses") }
        var orderedContacts = 0
        var solarTracks = 0
        for event in eclipses {
            if let a = event.contactStart, let b = event.contactEnd {
                guard a < event.maxTime && event.maxTime < b else { fatalError("bad contact ordering") }
                orderedContacts += 1
            }
            if event.kind.lowercased() == "solar" {
                let track = AstronomyParityEngine.eclipseGroundTrack(event)
                if !track.isEmpty {
                    guard track.allSatisfy({ (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) }) else {
                        fatalError("track out of bounds")
                    }
                    solarTracks += 1
                }
            }
        }
        guard orderedContacts > 0 else { fatalError("no contact intervals") }
        guard solarTracks > 0 else { fatalError("no solar track") }

        let occ = AstronomyParityEngine.occultations(site: site, from: start, days: 365)
        for event in occ where event.occultation {
            if let ingress = event.ingress, let egress = event.egress {
                guard ingress < event.time && event.time < egress else { fatalError("bad occultation contacts") }
            }
        }

        let csv = "satellite,start_utc,end_utc,duration_min\nAO-7,2026-08-15 00:00:00 UTC,2026-08-15 00:10:00 UTC,10.0\n"
        let pdf = OrbitExportService.planningReportPDF(title: "Planning Test", subtitle: "0.9.2 smoke", csvText: csv)
        guard !pdf.isEmpty else { fatalError("empty report") }
#if !canImport(UIKit)
        let text = String(data: pdf, encoding: .utf8) ?? ""
        guard text.contains("Planning Test") && text.contains("AO-7") else { fatalError("report fallback missing data") }
#endif
        print("PARITY092_OK eclipses=\(eclipses.count) contacts=\(orderedContacts) solarTracks=\(solarTracks) occultations=\(occ.count) reportBytes=\(pdf.count)")
    }
}
