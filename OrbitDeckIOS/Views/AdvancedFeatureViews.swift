import Foundation
import SwiftUI

// MARK: - OSCARLOCATOR simulator

private struct OscarGeoPoint: Identifiable, Sendable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
}

private struct OscarLabSnapshot: Sendable {
    let altitudeKm: Double
    let eccentricity: Double
    let inclination: Double
    let raan: Double
    let argumentOfPerigee: Double
    let meanAnomaly: Double
    let epoch: Date
}

private enum OscarChallenge: String, CaseIterable, Identifiable {
    case lowLEO = "Build a low-inclination LEO"
    case sunSync = "Build a Sun-synchronous LEO"
    case molniya = "Build a Molniya-like orbit"
    case geo = "Build a geostationary orbit"
    var id: String { rawValue }
    var hint: String {
        switch self {
        case .lowLEO: "Aim for 300–800 km, eccentricity near zero, and inclination below 10°."
        case .sunSync: "Try roughly 600–850 km, low eccentricity, and a retrograde inclination near 98°."
        case .molniya: "Use a high ellipse, 63.4° inclination, and argument of perigee near 270°."
        case .geo: "Find ~35,786 km altitude with near-zero eccentricity and inclination."
        }
    }
}

private enum OscarProjection: String, CaseIterable, Identifiable {
    case automatic = "Polar Auto"
    case north = "Polar North"
    case south = "Polar South"
    case qth = "QTH Centered"
    var id: String { rawValue }
}

private enum OscarDrive: String, CaseIterable, Identifiable {
    case live = "Live"
    case manual = "Manual"
    case nextPass = "Next Pass"
    var id: String { rawValue }
}

struct OscarLocatorView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var projection: OscarProjection = .automatic
    @State private var drive: OscarDrive = .live
    @State private var showRange = true
    @State private var showFootprint = true
    @State private var nodeDate = Date()
    @State private var nodeLongitude = 0.0
    @State private var minutesAfterNode = 0.0
    @State private var track: [OscarGeoPoint] = []
    @State private var look: LiveLook?
    @State private var error: String?
    @State private var useLabSatellite = false
    @State private var labEpoch = Date()
    @State private var labAltitudeKm = 420.0
    @State private var labEccentricity = 0.0
    @State private var labInclination = 51.6
    @State private var labRAAN = 0.0
    @State private var labArgumentOfPerigee = 0.0
    @State private var labMeanAnomaly = 0.0
    @State private var locatorPDFURL: URL?
    @State private var pdfKind: OscarPDFKind = .fullSet
    @State private var pdfCleanTransparencies = false
    @State private var compareSnapshot: OscarLabSnapshot?
    @State private var compareTrack: [OscarGeoPoint] = []
    @State private var compareLook: LiveLook?
    @State private var challenge: OscarChallenge?

    var body: some View {
        VStack(spacing: 0) {
            if useLabSatellite {
                HStack {
                    Image(systemName: "testtube.2")
                    Text("LAB-SAT").font(.headline)
                    Spacer()
                    Text(String(format: "%.0f km · i %.1f° · e %.3f", labAltitudeKm, labInclination, labEccentricity))
                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }.padding(.horizontal).padding(.vertical, 8).background(ODTheme.panel)
            } else {
                SelectedSatelliteHeader()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    locator
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    controls

                    if let look {
                        SectionCard("Readout") {
                            MetricRow(label: "Time", value: ODFormat.utc.string(from: displayDate))
                            MetricRow(label: "Sub-point", value: String(format: "%.2f°, %.2f°", look.subLatitude, look.subLongitude))
                            MetricRow(label: "Altitude", value: ODFormat.distance(look.altitudeKm))
                            MetricRow(label: "From QTH", value: String(format: "az %.0f° / el %+.1f°", look.azimuth, look.elevation), valueColor: look.elevation >= 0 ? ODTheme.good : ODTheme.muted)
                            MetricRow(label: "Footprint radius", value: ODFormat.distance(look.footprintRadiusKm))
                            if drive != .live {
                                MetricRow(label: "EQX", value: String(format: "%@  %.1f°%@", ODFormat.utcShort.string(from: nodeDate), abs(nodeLongitude), nodeLongitude >= 0 ? "E" : "W"))
                            }
                        }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(ODTheme.warning)
                    }
                    Text("Lab-orbit edits now support A/B ghost comparison and guided orbit-design challenges. Both the live lab orbit and the frozen comparison orbit flow through the same propagator used by catalog satellites.")
                        .font(.caption)
                        .foregroundStyle(ODTheme.muted)
                }
                .padding()
            }
        }
        .task { loadSavedLabOrbit(); await seedAndRefresh() }
        .onChange(of: store.preferences.selectedNorad) { Task { await seedAndRefresh() } }
        .onChange(of: projection) { Task { await refresh() } }
        .onChange(of: minutesAfterNode) { if drive != .live { Task { await refresh() } } }
        .onChange(of: nodeLongitude) { if drive != .live { Task { await refresh() } } }
        .onChange(of: drive) {
            Task {
                if drive == .nextPass { await seedNextPass() }
                else if drive == .manual { await seedManualNode() }
                await refresh()
            }
        }
        .onChange(of: useLabSatellite) {
            if useLabSatellite {
                labEpoch = .now
            } else {
                compareSnapshot = nil; compareTrack = []; compareLook = nil; challenge = nil
            }
            Task { await seedAndRefresh() }
        }
        .onChange(of: labAltitudeKm) { saveSharedLabOrbit(); if useLabSatellite { Task { await seedAndRefresh() } } }
        .onChange(of: labEccentricity) { saveSharedLabOrbit(); if useLabSatellite { Task { await seedAndRefresh() } } }
        .onChange(of: labInclination) { saveSharedLabOrbit(); if useLabSatellite { Task { await seedAndRefresh() } } }
        .onChange(of: labRAAN) { saveSharedLabOrbit(); if useLabSatellite { Task { await seedAndRefresh() } } }
        .onChange(of: labArgumentOfPerigee) { saveSharedLabOrbit(); if useLabSatellite { Task { await seedAndRefresh() } } }
        .onChange(of: labMeanAnomaly) { saveSharedLabOrbit(); if useLabSatellite { Task { await seedAndRefresh() } } }
        .overlay {
            if drive == .live {
                TimelineView(.periodic(from: .now, by: 2)) { context in
                    Color.clear.task(id: context.date.timeIntervalSince1970.rounded()) { await refresh() }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Drive", selection: $drive) {
                ForEach(OscarDrive.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Projection", selection: $projection) {
                ForEach(OscarProjection.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("QTH range circle", isOn: $showRange)
            Toggle("Satellite footprint", isOn: $showFootprint)
            Divider()
            Toggle("Use lab satellite", isOn: $useLabSatellite)
            if useLabSatellite {
                DisclosureGroup("Lab orbital elements") {
                    Menu {
                        Button("ISS-like LEO") { applyLabPreset("iss") }
                        Button("Sun-synchronous") { applyLabPreset("sso") }
                        Button("Polar") { applyLabPreset("polar") }
                        Button("Molniya") { applyLabPreset("molniya") }
                        Button("GPS-like MEO") { applyLabPreset("gps") }
                        Button("Geostationary") { applyLabPreset("geo") }
                    } label: { Label("Preset orbit", systemImage: "slider.horizontal.3") }
                    labSlider("Mean altitude", value: $labAltitudeKm, range: 200...40000, unit: "km")
                    labSlider("Eccentricity", value: $labEccentricity, range: 0...0.70, unit: "")
                    labSlider("Inclination", value: $labInclination, range: 0...180, unit: "°")
                    labSlider("RAAN", value: $labRAAN, range: 0...360, unit: "°")
                    labSlider("Arg. perigee", value: $labArgumentOfPerigee, range: 0...360, unit: "°")
                    labSlider("Mean anomaly", value: $labMeanAnomaly, range: 0...360, unit: "°")
                    if let sat = activeSatellite {
                        Text(String(format: "Period %.1f min · perigee %.0f km · apogee %.0f km", sat.periodMinutes, sat.perigeeKm, sat.apogeeKm))
                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                        Text(labOrbitType).font(.caption).foregroundStyle(ODTheme.good)
                    }
                    Button("Save lab satellite to catalog") { saveLabSatellite() }
                    Divider()
                    if compareSnapshot == nil {
                        Button { freezeComparison() } label: { Label("Freeze current orbit as comparison B", systemImage: "square.on.square") }
                    } else {
                        HStack {
                            Label("Comparison B frozen", systemImage: "checkmark.circle").foregroundStyle(ODTheme.good)
                            Spacer()
                            Button("Clear") { compareSnapshot = nil; compareTrack = []; compareLook = nil }
                        }
                    }
                    Menu {
                        ForEach(OscarChallenge.allCases) { item in
                            Button(item.rawValue) { challenge = item }
                        }
                        if challenge != nil { Divider(); Button("End challenge") { challenge = nil } }
                    } label: { Label("Guided challenge", systemImage: "graduationcap") }
                    if let challenge {
                        Text(challenge.rawValue).font(.caption.bold())
                        Text(challenge.hint).font(.caption).foregroundStyle(ODTheme.muted)
                        Label(challengeComplete(challenge) ? "Challenge complete" : "Adjust the elements to meet the goal", systemImage: challengeComplete(challenge) ? "checkmark.seal.fill" : "circle.dashed")
                            .font(.caption).foregroundStyle(challengeComplete(challenge) ? ODTheme.good : ODTheme.warning)
                    }
                    DisclosureGroup("Orbital element glossary") {
                        Text("Mean altitude sets semi-major axis and therefore orbital period.")
                        Text("Eccentricity controls how elongated the orbit is; zero is circular.")
                        Text("Inclination sets the maximum latitude of the ground track; values above 90° are retrograde.")
                        Text("RAAN rotates the orbit plane around Earth's axis.")
                        Text("Argument of perigee rotates the ellipse inside its plane.")
                        Text("Mean anomaly moves the spacecraft along the same orbit at the epoch.")
                    }.font(.caption).foregroundStyle(ODTheme.muted)
                }
            }
            if drive != .live {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "EQX longitude: %.1f°%@", abs(nodeLongitude), nodeLongitude >= 0 ? "E" : "W"))
                        .font(.caption.monospacedDigit())
                    Slider(value: $nodeLongitude, in: -180...180, step: 1)
                    Text("Minutes after equator crossing: \(Int(minutesAfterNode.rounded()))")
                        .font(.caption.monospacedDigit())
                    Slider(value: $minutesAfterNode, in: 0...max(1, activeSatellite?.periodMinutes ?? 95), step: 1)
                }
                HStack {
                    Button("Previous EQX") { Task { await shiftNode(-1) } }
                    Button("Next EQX") { Task { await shiftNode(1) } }
                }
            }
            Button {
                drive = .nextPass
            } label: {
                Label("Seed from next visible pass", systemImage: "forward.end")
            }
            Button {
                drive = .live
            } label: {
                Label("Go live", systemImage: "dot.radiowaves.left.and.right")
            }
            Picker("Printable", selection: $pdfKind) {
                ForEach(OscarPDFKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            if pdfKind != .baseMap {
                Toggle("Clean transparencies (no overlay text)", isOn: $pdfCleanTransparencies)
                    .font(.caption)
            }
            Button { prepareLocatorPDF() } label: {
                Label("Prepare \(pdfKind.rawValue)", systemImage: "doc.richtext")
            }
            if let locatorPDFURL {
                ShareLink(item: locatorPDFURL) { Label("Share OSCARLOCATOR PDF", systemImage: "square.and.arrow.up") }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .odPanel()
    }

    private var locator: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = max(1, side / 2 - 28)
            let mode = resolvedProjection

            for ring in stride(from: 30.0, through: 90.0, by: 30.0) {
                let r = radius * ring / 90.0
                context.stroke(Path(ellipseIn: CGRect(x: center.x-r, y: center.y-r, width: 2*r, height: 2*r)), with: .color(ODTheme.grid), lineWidth: ring == 90 ? 1.6 : 0.8)
            }
            var radials = Path()
            for a in stride(from: 0.0, to: 360.0, by: 30.0) {
                let theta = a * .pi / 180
                let edge: CGPoint
                if mode == .qth {
                    edge = CGPoint(x: center.x + radius * sin(theta), y: center.y - radius * cos(theta))
                } else {
                    let sign = mode == .south ? -1.0 : 1.0
                    edge = CGPoint(x: center.x + sign * radius * sin(theta), y: center.y + radius * cos(theta))
                }
                radials.move(to: center); radials.addLine(to: edge)
            }
            context.stroke(radials, with: .color(ODTheme.grid.opacity(0.75)), lineWidth: 0.7)

            if mode == .qth {
                for (label, angle) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                    let t = angle * .pi / 180
                    let p = CGPoint(x: center.x + (radius+14)*sin(t), y: center.y - (radius+14)*cos(t))
                    context.draw(Text(label).font(.caption.bold()).foregroundStyle(ODTheme.muted), at: p)
                }
            } else {
                for lon in stride(from: -150, through: 180, by: 30) {
                    let t = Double(lon) * .pi / 180
                    let sign = mode == .south ? -1.0 : 1.0
                    let p = CGPoint(x: center.x + sign*(radius+14)*sin(t), y: center.y + (radius+14)*cos(t))
                    context.draw(Text("\(abs(lon))°\(lon < 0 ? "W" : lon > 0 ? "E" : "")").font(.system(size: 7, design: .monospaced)).foregroundStyle(ODTheme.muted), at: p)
                }
            }

            // Coastline base map projected onto the azimuthal disc (this is the
            // OSCARLOCATOR's underlying world map).
            let landColor = ODTheme.mapLand
            for polyline in WorldMapData.coastlines {
                drawGeoPath(polyline.map { OscarGeoPoint(latitude: $0.1, longitude: $0.0) },
                            mode: mode, center: center, radius: radius, context: &context,
                            color: landColor, width: 0.8)
            }

            if !compareTrack.isEmpty {
                drawGeoPath(compareTrack, mode: mode, center: center, radius: radius, context: &context, color: ODTheme.muted, width: 1.4, dashed: true)
                if let compareLook, showFootprint {
                    let ghostCircle = destinationCircle(latitude: compareLook.subLatitude, longitude: compareLook.subLongitude, radiusDeg: footprintAngle(altitudeKm: compareLook.altitudeKm))
                    drawGeoPath(ghostCircle, mode: mode, center: center, radius: radius, context: &context, color: ODTheme.muted, width: 1.0, dashed: true)
                }
            }
            drawGeoPath(track, mode: mode, center: center, radius: radius, context: &context, color: ODTheme.accent, width: 2.2)

            if showRange, let sat = activeSatellite {
                let angular = footprintAngle(altitudeKm: max(1, sat.semiMajorAxisKm - OrbitPredictor.earthRadiusKm))
                let circle = destinationCircle(latitude: store.preferences.observer.latitude, longitude: store.preferences.observer.longitude, radiusDeg: angular)
                drawGeoPath(circle, mode: mode, center: center, radius: radius, context: &context, color: ODTheme.warning, width: 1.3, dashed: true)
            }
            if showFootprint, let look {
                let angular = footprintAngle(altitudeKm: look.altitudeKm)
                let circle = destinationCircle(latitude: look.subLatitude, longitude: look.subLongitude, radiusDeg: angular)
                drawGeoPath(circle, mode: mode, center: center, radius: radius, context: &context, color: ODTheme.good, width: 1.2, dashed: true)
            }

            if let q = projected(latitude: store.preferences.observer.latitude, longitude: store.preferences.observer.longitude, mode: mode, center: center, radius: radius) {
                context.fill(Path(ellipseIn: CGRect(x: q.x-4, y: q.y-4, width: 8, height: 8)), with: .color(ODTheme.warning))
            }
            if let look, let p = projected(latitude: look.subLatitude, longitude: look.subLongitude, mode: mode, center: center, radius: radius) {
                context.fill(Path(ellipseIn: CGRect(x: p.x-6, y: p.y-6, width: 12, height: 12)), with: .color(ODTheme.good))
                context.stroke(Path(ellipseIn: CGRect(x: p.x-9, y: p.y-9, width: 18, height: 18)), with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
        }
        .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("OSCARLOCATOR simulator")
    }

    private func loadSavedLabOrbit() {
        guard let saved = store.preferences.labOrbit else { return }
        labAltitudeKm = saved.altitudeKm
        labEccentricity = saved.eccentricity
        labInclination = saved.inclinationDeg
        labRAAN = saved.raanDeg
        labArgumentOfPerigee = saved.argumentOfPerigeeDeg
        labMeanAnomaly = saved.meanAnomalyDeg
    }

    private func saveSharedLabOrbit() {
        store.preferences.labOrbit = LabOrbitDefinition(
            altitudeKm: labAltitudeKm, eccentricity: labEccentricity,
            inclinationDeg: labInclination, raanDeg: labRAAN,
            argumentOfPerigeeDeg: labArgumentOfPerigee, meanAnomalyDeg: labMeanAnomaly)
    }

    private var activeSatellite: SatelliteRecord? {
        guard useLabSatellite else { return store.selectedSatellite }
        let meanMotion = labMeanMotion(altitudeKm: labAltitudeKm)
        let definition = ManualSatelliteDefinition(
            name: "LAB-SAT", norad: 99000, internationalDesignator: "LAB", epoch: labEpoch,
            inclinationDeg: labInclination, raanDeg: labRAAN,
            eccentricity: min(0.70, max(0, labEccentricity)),
            argumentOfPerigeeDeg: labArgumentOfPerigee, meanAnomalyDeg: labMeanAnomaly,
            meanMotionRevPerDay: meanMotion, bstar: 0)
        return GPService.makeManualRecord(definition)
    }

    private func labMeanMotion(altitudeKm: Double) -> Double {
        let mu = 398600.4418, radius = 6378.135 + min(40000, max(200, altitudeKm))
        return sqrt(mu / pow(radius, 3)) * 86400 / (2 * .pi)
    }

    @ViewBuilder private func labSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(String(format: unit.isEmpty ? "%.3f" : "%.1f", value.wrappedValue)) \(unit)")
                .font(.caption.monospacedDigit())
            Slider(value: value, in: range)
        }
    }

    private var labOrbitType: String {
        if labAltitudeKm >= 34_000 && labEccentricity < 0.05 { return labInclination < 1 ? "Geostationary" : "Geosynchronous" }
        if labEccentricity >= 0.5 && (60...65).contains(labInclination) && labAltitudeKm > 20_000 { return "Molniya-like high ellipse" }
        if labEccentricity >= 0.4 { return "Highly elliptical orbit" }
        if labAltitudeKm >= 8_000 { return "Medium Earth orbit" }
        if (96...102).contains(labInclination) { return "Sun-synchronous-like LEO" }
        if labInclination > 102 { return "Retrograde LEO" }
        if labInclination < 20 { return "Low-inclination LEO" }
        return "Low Earth orbit"
    }

    @MainActor private func applyLabPreset(_ preset: String) {
        switch preset {
        case "iss": labAltitudeKm=420; labEccentricity=0; labInclination=51.6; labRAAN=0; labArgumentOfPerigee=0; labMeanAnomaly=0
        case "sso": labAltitudeKm=700; labEccentricity=0.001; labInclination=98.2; labRAAN=0; labArgumentOfPerigee=0; labMeanAnomaly=0
        case "polar": labAltitudeKm=800; labEccentricity=0; labInclination=90; labRAAN=0; labArgumentOfPerigee=0; labMeanAnomaly=0
        case "molniya": labAltitudeKm=26_600; labEccentricity=0.70; labInclination=63.4; labRAAN=0; labArgumentOfPerigee=270; labMeanAnomaly=0
        case "gps": labAltitudeKm=20_200; labEccentricity=0; labInclination=55; labRAAN=0; labArgumentOfPerigee=0; labMeanAnomaly=0
        case "geo": labAltitudeKm=35_786; labEccentricity=0; labInclination=0; labRAAN=0; labArgumentOfPerigee=0; labMeanAnomaly=0
        default: return
        }
        labEpoch = .now
        Task { await seedAndRefresh() }
    }

    @MainActor private func prepareLocatorPDF() {
        guard let sat = activeSatellite else { return }
        // Match the printable hemisphere to the selected on-screen projection;
        // QTH-centred and auto fall back to the observer's own hemisphere.
        let south: Bool?
        switch resolvedProjection {
        case .north: south = false
        case .south: south = true
        default: south = nil
        }
        do {
            let data = OrbitExportService.oscarLocatorPDF(satellite: sat, observer: store.preferences.observer,
                                                          at: displayDate, kind: pdfKind,
                                                          cleanTransparencies: pdfCleanTransparencies,
                                                          southHemisphere: south)
            locatorPDFURL = try OrbitExportService.temporaryFile(name: "oscarlocator_\(sat.name.replacingOccurrences(of: "/", with: "-")).pdf", data: data)
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func saveLabSatellite() {
        var norad: UInt = 99000
        let used = Set(store.satellites.map(\.id))
        while used.contains(norad) { norad += 1 }
        let definition = ManualSatelliteDefinition(
            name: "LAB-SAT", norad: norad, internationalDesignator: "LAB", epoch: labEpoch,
            inclinationDeg: labInclination, raanDeg: labRAAN, eccentricity: min(0.70, max(0, labEccentricity)),
            argumentOfPerigeeDeg: labArgumentOfPerigee, meanAnomalyDeg: labMeanAnomaly,
            meanMotionRevPerDay: labMeanMotion(altitudeKm: labAltitudeKm), bstar: 0)
        store.saveManualSatellite(definition)
        error = "Saved LAB-SAT as manual satellite NORAD \(norad)."
    }

    @MainActor private func freezeComparison() {
        compareSnapshot = OscarLabSnapshot(altitudeKm: labAltitudeKm, eccentricity: labEccentricity, inclination: labInclination, raan: labRAAN, argumentOfPerigee: labArgumentOfPerigee, meanAnomaly: labMeanAnomaly, epoch: labEpoch)
        Task { await refresh() }
    }

    private func labSatellite(from snap: OscarLabSnapshot, norad: UInt) -> SatelliteRecord {
        GPService.makeManualRecord(.init(name: "LAB-B", norad: norad, internationalDesignator: "LAB", epoch: snap.epoch, inclinationDeg: snap.inclination, raanDeg: snap.raan, eccentricity: min(0.70, max(0, snap.eccentricity)), argumentOfPerigeeDeg: snap.argumentOfPerigee, meanAnomalyDeg: snap.meanAnomaly, meanMotionRevPerDay: labMeanMotion(altitudeKm: snap.altitudeKm), bstar: 0))
    }

    private func challengeComplete(_ item: OscarChallenge) -> Bool {
        switch item {
        case .lowLEO:
            return (300...800).contains(labAltitudeKm) && labEccentricity < 0.03 && labInclination < 10
        case .sunSync:
            return (600...850).contains(labAltitudeKm) && labEccentricity < 0.03 && (96...100).contains(labInclination)
        case .molniya:
            return (22000...31000).contains(labAltitudeKm) && labEccentricity > 0.60 && (62...65).contains(labInclination) && (255...285).contains(labArgumentOfPerigee)
        case .geo:
            return (35000...36500).contains(labAltitudeKm) && labEccentricity < 0.02 && labInclination < 2
        }
    }

    private var displayDate: Date {
        drive == .live ? .now : nodeDate.addingTimeInterval(minutesAfterNode * 60)
    }

    private var resolvedProjection: OscarProjection {
        switch projection {
        case .automatic:
            if let look { return look.subLatitude < 0 ? .south : .north }
            return store.preferences.observer.latitude < 0 ? .south : .north
        default: return projection
        }
    }

    @MainActor private func seedAndRefresh() async {
        if drive != .live { await seedManualNode() }
        await refresh()
    }

    @MainActor private func refresh() async {
        guard let sat = activeSatellite else { track = []; look = nil; return }
        do {
            let date = displayDate
            let gt = try OrbitPredictor.groundTrack(sat, centeredAt: date, durationMinutes: max(1, sat.periodMinutes), step: 45)
            var current = try OrbitPredictor.look(sat, observer: store.preferences.observer, at: date)
            if drive == .live {
                track = gt.map { OscarGeoPoint(latitude: $0.1, longitude: $0.2) }
            } else {
                // Rotate the propagated orbit east/west so its selected equator
                // crossing sits at the operator-controlled EQX longitude. This
                // is the digital equivalent of rotating the OSCARLOCATOR overlay.
                let trueNode = try OrbitPredictor.subpoint(sat, at: nodeDate)
                let delta = wrappedLongitude(nodeLongitude - trueNode.longitude)
                track = gt.map { OscarGeoPoint(latitude: $0.1, longitude: wrappedLongitude($0.2 + delta)) }
                current.subLongitude = wrappedLongitude(current.subLongitude + delta)
                let topo = topocentric(latitude: current.subLatitude,
                                       longitude: current.subLongitude,
                                       altitudeKm: current.altitudeKm,
                                       observer: store.preferences.observer)
                current.azimuth = topo.azimuth
                current.elevation = topo.elevation
                current.rangeKm = topo.rangeKm
            }
            look = current
            if let compareSnapshot {
                let ghost = labSatellite(from: compareSnapshot, norad: 99001)
                let ghostGT = try OrbitPredictor.groundTrack(ghost, centeredAt: date, durationMinutes: max(1, ghost.periodMinutes), step: 45)
                var ghostCurrent = try OrbitPredictor.look(ghost, observer: store.preferences.observer, at: date)
                if drive == .live {
                    compareTrack = ghostGT.map { OscarGeoPoint(latitude: $0.1, longitude: $0.2) }
                } else {
                    let trueGhostNode = try OrbitPredictor.subpoint(ghost, at: nodeDate)
                    let ghostDelta = wrappedLongitude(nodeLongitude - trueGhostNode.longitude)
                    compareTrack = ghostGT.map { OscarGeoPoint(latitude: $0.1, longitude: wrappedLongitude($0.2 + ghostDelta)) }
                    ghostCurrent.subLongitude = wrappedLongitude(ghostCurrent.subLongitude + ghostDelta)
                    let topo = topocentric(latitude: ghostCurrent.subLatitude, longitude: ghostCurrent.subLongitude, altitudeKm: ghostCurrent.altitudeKm, observer: store.preferences.observer)
                    ghostCurrent.azimuth = topo.azimuth; ghostCurrent.elevation = topo.elevation; ghostCurrent.rangeKm = topo.rangeKm
                }
                compareLook = ghostCurrent
            } else {
                compareTrack = []; compareLook = nil
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func seedManualNode() async {
        guard let sat = activeSatellite else { return }
        do {
            let asc = store.preferences.observer.latitude >= 0
            let start = Date().addingTimeInterval(-sat.periodMinutes * 60 * 1.5)
            let end = Date().addingTimeInterval(sat.periodMinutes * 60 * 1.5)
            let crossings = try OrbitPredictor.equatorCrossings(sat, from: start, to: end, ascending: asc)
            let closest = crossings.min { abs($0.0.timeIntervalSinceNow) < abs($1.0.timeIntervalSinceNow) }
            if let closest { nodeDate = closest.0; nodeLongitude = closest.1; minutesAfterNode = max(0, Date().timeIntervalSince(nodeDate)/60).truncatingRemainder(dividingBy: max(1, sat.periodMinutes)) }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func seedNextPass() async {
        guard let sat = activeSatellite else { return }
        do {
            let passes = try OrbitPredictor.predictPasses(sat, observer: store.preferences.observer, minElevation: store.preferences.minElevation, maxCount: 1, horizonDays: 3)
            guard let pass = passes.first else { error = "No visible pass found in the next three days."; return }
            let asc = store.preferences.observer.latitude >= 0
            let span = max(9000, sat.periodMinutes * 60 * 1.6)
            let crossings = try OrbitPredictor.equatorCrossings(sat, from: pass.aos.addingTimeInterval(-span), to: pass.aos.addingTimeInterval(600), ascending: asc)
            let prior = crossings.filter { $0.0 <= pass.aos.addingTimeInterval(60) }.last
            nodeDate = prior?.0 ?? pass.aos
            nodeLongitude = try prior?.1 ?? OrbitPredictor.subpoint(sat, at: nodeDate).longitude
            minutesAfterNode = 0
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func shiftNode(_ direction: Int) async {
        guard let sat = activeSatellite else { return }
        do {
            let asc = store.preferences.observer.latitude >= 0
            let period = max(60, sat.periodMinutes * 60)
            let center = nodeDate.addingTimeInterval(Double(direction) * period)
            let crossings = try OrbitPredictor.equatorCrossings(sat, from: center.addingTimeInterval(-period * 0.6), to: center.addingTimeInterval(period * 0.6), ascending: asc)
            if let c = crossings.min(by: { abs($0.0.timeIntervalSince(center)) < abs($1.0.timeIntervalSince(center)) }) {
                nodeDate = c.0; nodeLongitude = c.1; minutesAfterNode = 0
            }
        } catch { self.error = error.localizedDescription }
    }

    private func wrappedLongitude(_ longitude: Double) -> Double {
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    private func topocentric(latitude: Double, longitude: Double, altitudeKm: Double,
                             observer: ObserverSite) -> (azimuth: Double, elevation: Double, rangeKm: Double) {
        let re = OrbitPredictor.earthRadiusKm
        let slat = latitude * .pi / 180, slon = longitude * .pi / 180
        let olat = observer.latitude * .pi / 180, olon = observer.longitude * .pi / 180
        let sr = re + altitudeKm, or = re + observer.altitudeMeters / 1000
        let sx = sr * cos(slat) * cos(slon), sy = sr * cos(slat) * sin(slon), sz = sr * sin(slat)
        let ox = or * cos(olat) * cos(olon), oy = or * cos(olat) * sin(olon), oz = or * sin(olat)
        let dx = sx - ox, dy = sy - oy, dz = sz - oz
        let east = -sin(olon) * dx + cos(olon) * dy
        let north = -sin(olat) * cos(olon) * dx - sin(olat) * sin(olon) * dy + cos(olat) * dz
        let up = cos(olat) * cos(olon) * dx + cos(olat) * sin(olon) * dy + sin(olat) * dz
        let range = sqrt(dx*dx + dy*dy + dz*dz)
        var az = atan2(east, north) * 180 / .pi
        if az < 0 { az += 360 }
        let el = atan2(up, hypot(east, north)) * 180 / .pi
        return (az, el, range)
    }

    private func footprintAngle(altitudeKm: Double) -> Double {
        acos(max(-1, min(1, OrbitPredictor.earthRadiusKm / (OrbitPredictor.earthRadiusKm + max(1, altitudeKm))))) * 180 / .pi
    }

    private func destinationCircle(latitude: Double, longitude: Double, radiusDeg: Double) -> [OscarGeoPoint] {
        let p1 = latitude * .pi / 180, l1 = longitude * .pi / 180, d = radiusDeg * .pi / 180
        return stride(from: 0.0, through: 360.0, by: 4.0).map { bearing in
            let b = bearing * .pi / 180
            let lat2 = asin(sin(p1)*cos(d) + cos(p1)*sin(d)*cos(b))
            let lon2 = l1 + atan2(sin(b)*sin(d)*cos(p1), cos(d)-sin(p1)*sin(lat2))
            var lon = lon2 * 180 / .pi
            while lon > 180 { lon -= 360 }; while lon < -180 { lon += 360 }
            return OscarGeoPoint(latitude: lat2 * 180 / .pi, longitude: lon)
        }
    }

    private func drawGeoPath(_ points: [OscarGeoPoint], mode: OscarProjection, center: CGPoint, radius: Double, context: inout GraphicsContext, color: Color, width: Double, dashed: Bool = false) {
        var path = Path(); var open = false; var previous: CGPoint?
        for geo in points {
            guard let p = projected(latitude: geo.latitude, longitude: geo.longitude, mode: mode, center: center, radius: radius) else { open = false; previous = nil; continue }
            if let previous, hypot(p.x-previous.x, p.y-previous.y) > radius * 0.8 { open = false }
            if open { path.addLine(to: p) } else { path.move(to: p); open = true }
            previous = p
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dashed ? [5,4] : []))
    }

    private func projected(latitude: Double, longitude: Double, mode: OscarProjection, center: CGPoint, radius: Double) -> CGPoint? {
        let rho: Double, theta: Double, south: Bool
        switch mode {
        case .north, .automatic:
            rho = 90 - latitude; theta = longitude * .pi / 180; south = false
        case .south:
            rho = 90 + latitude; theta = longitude * .pi / 180; south = true
        case .qth:
            let gc = greatCircle(fromLat: store.preferences.observer.latitude, fromLon: store.preferences.observer.longitude, toLat: latitude, toLon: longitude)
            guard gc.distanceDeg <= 90 else { return nil }
            let r = radius * gc.distanceDeg / 90
            let t = gc.bearingDeg * .pi / 180
            return CGPoint(x: center.x + r*sin(t), y: center.y - r*cos(t))
        }
        guard rho >= 0 && rho <= 90 else { return nil }
        let r = radius * rho / 90
        let sign = south ? -1.0 : 1.0
        return CGPoint(x: center.x + sign*r*sin(theta), y: center.y + r*cos(theta))
    }

    private func greatCircle(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> (distanceDeg: Double, bearingDeg: Double) {
        let p1 = fromLat * .pi/180, p2 = toLat * .pi/180, dl = (toLon-fromLon) * .pi/180
        let ca = max(-1, min(1, sin(p1)*sin(p2)+cos(p1)*cos(p2)*cos(dl)))
        let d = acos(ca) * 180 / .pi
        let y = sin(dl)*cos(p2), x = cos(p1)*sin(p2)-sin(p1)*cos(p2)*cos(dl)
        let b = (atan2(y,x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (d,b)
    }
}

// MARK: - Exports and pass alarms

struct ExportsView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var days = 3
    @State private var passes: [PredictedPass] = []
    @State private var shareURL: URL?
    @State private var shareLabel = ""
    @State private var status = ""
    @State private var loading = false
    @State private var comparison: [PassComparisonEntry] = []
    @State private var cardPassIndex = 0
    @State private var referenceDays = 60
    @State private var referenceFavorites = false

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCard("Pass schedule") {
                        Picker("Window", selection: $days) {
                            Text("1 day").tag(1); Text("3 days").tag(3); Text("7 days").tag(7)
                        }.pickerStyle(.segmented)
                        HStack {
                            Button("CSV") { prepare(.csv) }
                            Button("Excel") { prepare(.xlsx) }
                            Button("iCalendar") { prepare(.ics) }
                            Button("JSON") { prepare(.json) }
                            Button("PDF Report") { prepare(.pdf) }
                            if loading { ProgressView() }
                        }
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share \(shareLabel)", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Text(status).font(.caption).foregroundStyle(ODTheme.muted)
                    }

                    SectionCard("Compare favorites") {
                        Text("Compare favorite satellites over the same planning window and export the rollup as CSV.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        Button { Task { await prepareComparison() } } label: {
                            Label("Compute favorite comparison", systemImage: "tablecells")
                        }
                        if !comparison.isEmpty {
                            ForEach(comparison.prefix(16)) { entry in
                                HStack {
                                    Text(entry.satellite.name).lineLimit(1)
                                    Spacer()
                                    Text("\(entry.passCount) passes")
                                    if let best = entry.bestPass {
                                        Text("best \(ODFormat.angle(best.maxElevation, decimals: 0))")
                                            .foregroundStyle(ODTheme.muted)
                                    }
                                }.font(.caption)
                            }
                        }
                    }

                    SectionCard("Pass card") {
                        Text("Create a shareable summary card with the sky track, 145.8 MHz Doppler curve and key pass facts.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        if !passes.isEmpty {
                            Picker("Pass", selection: $cardPassIndex) {
                                ForEach(Array(passes.prefix(12).enumerated()), id: \.offset) { index, pass in
                                    Text("\(ODFormat.utcShort.string(from: pass.aos)) · \(ODFormat.angle(pass.maxElevation, decimals: 0))").tag(index)
                                }
                            }
                            Button { preparePassCard() } label: {
                                Label("Prepare PNG pass card", systemImage: "photo")
                            }
                        } else {
                            Text("No upcoming pass is available.").foregroundStyle(ODTheme.muted)
                        }
                    }

                    SectionCard("Desktop reports") {
                        Text("Printable operational reports using the same propagated results as the live screens. The complete satellite report includes analysis, passes, EQX, sky tracks, a 60-day illumination raster and 30-day progression; the two graphic reports are also available separately.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        ViewThatFits {
                            HStack {
                                Button("Satellite report PDF") { Task { await prepareSatelliteReport() } }
                                Button("Favorites schedule PDF") { prepareFavoritesReport() }
                                Button("Sites comparison PDF") { prepareSitesReport() }
                            }
                            VStack(alignment: .leading) {
                                Button("Satellite report PDF") { Task { await prepareSatelliteReport() } }
                                Button("Favorites chronological schedule PDF") { prepareFavoritesReport() }
                                Button("Selected satellite by site PDF") { prepareSitesReport() }
                            }
                        }
                        ViewThatFits {
                            HStack {
                                Button("Illumination PDF") { Task { await prepareIlluminationReport() } }
                                Button("30-day progression PDF") { Task { await prepareProgressionReport() } }
                            }
                            VStack(alignment: .leading) {
                                Button("60-day illumination PDF") { Task { await prepareIlluminationReport() } }
                                Button("30-day pass progression PDF") { Task { await prepareProgressionReport() } }
                            }
                        }
                        if loading { ProgressView() }
                        if let shareURL {
                            ShareLink(item: shareURL) { Label("Share \(shareLabel)", systemImage: "square.and.arrow.up") }
                        }
                    }

                    SectionCard("Listings & reference orbits") {
                        Text("Desktop-style compact pass, equator-crossing and stepped ephemeris exports. Position listings include az/el/range, range-rate, sub-point, altitude and Sun/shadow state.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        ViewThatFits {
                            HStack {
                                Button("AOS/LOS CSV") { prepareCompactListing() }
                                Button("EQX CSV") { Task { await prepareEquatorCrossings() } }
                                Button("6 h position CSV") { prepareSteppedListing() }
                            }
                            VStack(alignment:.leading) {
                                Button("AOS/LOS CSV") { prepareCompactListing() }
                                Button("Equator-crossing CSV") { Task { await prepareEquatorCrossings() } }
                                Button("6 h position listing CSV") { prepareSteppedListing() }
                            }
                        }
                        if let second = store.preferences.savedSites?.first {
                            Button("3 h two-site listing: \(store.preferences.observer.name) + \(second.name)") { prepareTwoSiteListing(second) }
                        }
                        Divider()
                        Text("Physical OSCARLOCATOR reference orbits").font(.headline)
                        Text("For each UTC day, export the first ascending equator crossing for a northern station or descending crossing for a southern station. The UTC time and sub-longitude are the settings used by a physical OSCARLOCATOR reference overlay.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        Picker("Span", selection: $referenceDays) {
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                        }.pickerStyle(.segmented)
                        Toggle("All favorite satellites", isOn: $referenceFavorites)
                        Button { prepareReferenceOrbits() } label: {
                            Label("Prepare reference-orbits PDF", systemImage: "doc.richtext")
                        }
                    }

                    SectionCard("Local pass alarms") {
                        Text("Notification permission is requested only when you schedule your first pass alarm.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        ForEach(passes.prefix(12)) { pass in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(ODFormat.utcShort.string(from: pass.aos)).font(.body.monospacedDigit())
                                    Text("max \(ODFormat.angle(pass.maxElevation, decimals: 0)) • \(ODFormat.duration(pass.duration))")
                                        .font(.caption).foregroundStyle(ODTheme.muted)
                                }
                                Spacer()
                                Button {
                                    Task { await schedule(pass) }
                                } label: {
                                    Label("Alarm", systemImage: "bell.badge")
                                }
                            }
                            Divider().overlay(ODTheme.grid)
                        }
                    }
                }.padding()
            }
        }
        .task { await reload() }
        .onChange(of: days) { Task { await reload() } }
        .onChange(of: store.preferences.selectedNorad) { Task { await reload() } }
    }

    private enum ExportKind { case csv, xlsx, ics, json, pdf }

    @MainActor private func reload() async {
        guard let sat = store.selectedSatellite else { passes = []; return }
        loading = true; defer { loading = false }
        do {
            passes = try OrbitPredictor.predictPasses(sat, observer: store.preferences.observer, minElevation: store.preferences.minElevation, maxCount: 200, horizonDays: Double(days))
            if cardPassIndex >= min(passes.count, 12) { cardPassIndex = 0 }
            comparison = []
            status = "\(passes.count) passes over \(days) day(s)."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepare(_ kind: ExportKind) {
        guard let sat = store.selectedSatellite, !passes.isEmpty else { status = "No passes to export."; return }
        do {
            let base = sat.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            switch kind {
            case .csv:
                shareURL = try OrbitExportService.temporaryTextFile(name: "passes_\(base).csv", text: OrbitExportService.passesCSV(passes, satellite: sat, observer: store.preferences.observer)); shareLabel = "CSV"
            case .xlsx:
                shareURL = try OrbitExportService.temporaryFile(name: "passes_\(base).xlsx", data: OrbitExportService.passScheduleXLSX(passes, satellite: sat, observer: store.preferences.observer)); shareLabel = "Excel workbook"
            case .ics:
                shareURL = try OrbitExportService.temporaryTextFile(name: "passes_\(base).ics", text: OrbitExportService.passesICS(passes, satellite: sat, observer: store.preferences.observer, leadMinutes: store.preferences.passAlarmLeadMinutes ?? 10)); shareLabel = "iCalendar"
            case .json:
                shareURL = try OrbitExportService.temporaryFile(name: "passes_\(base).json", data: OrbitExportService.passesJSON(passes, satellite: sat, observer: store.preferences.observer, minElevation: store.preferences.minElevation)); shareLabel = "JSON"
            case .pdf:
                shareURL = try OrbitExportService.temporaryFile(name: "passes_\(base).pdf", data: OrbitExportService.passReportPDF(passes, satellite: sat, observer: store.preferences.observer, minElevation: store.preferences.minElevation)); shareLabel = "PDF"
            }
            status = "Prepared \(shareLabel) export for the system share sheet."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareComparison() async {
        let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
        guard !favorites.isEmpty else { comparison = []; status = "Mark satellites as favorites first."; return }
        loading = true; defer { loading = false }
        var rows: [PassComparisonEntry] = []
        for satellite in favorites.prefix(40) {
            let ps = (try? OrbitPredictor.predictPasses(satellite, observer: store.preferences.observer, minElevation: store.preferences.minElevation, maxCount: 100, horizonDays: Double(days))) ?? []
            rows.append(.init(satellite: satellite, passCount: ps.count, bestPass: ps.max(by: { $0.maxElevation < $1.maxElevation })))
        }
        comparison = rows.sorted { lhs, rhs in
            let le = lhs.bestPass?.maxElevation ?? -90, re = rhs.bestPass?.maxElevation ?? -90
            return le == re ? lhs.satellite.name < rhs.satellite.name : le > re
        }
        do {
            shareURL = try OrbitExportService.temporaryTextFile(name: "favorite_pass_comparison.csv", text: OrbitExportService.comparisonCSV(comparison, observer: store.preferences.observer, days: days))
            shareLabel = "comparison CSV"
            status = "Compared \(comparison.count) favorite satellite(s); CSV is ready to share."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func preparePassCard() {
        guard let satellite = store.selectedSatellite, !passes.isEmpty else { status = "No pass to render."; return }
        let index = max(0, min(cardPassIndex, min(passes.count, 12) - 1))
        let pass = passes[index]
        do {
            let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            shareURL = try OrbitExportService.temporaryFile(name: "passcard_\(base).png", data: OrbitExportService.passCardPNG(pass: pass, satellite: satellite, observer: store.preferences.observer))
            shareLabel = "pass card"
            status = "Pass card prepared for the system share sheet."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareSatelliteReport() async {
        guard let satellite = store.selectedSatellite else { status = "Select a satellite first."; return }
        let observer = store.preferences.observer
        let minimum = store.preferences.minElevation
        let reportDays = max(3, days)
        loading = true
        defer { loading = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try OrbitExportService.satelliteReportPDF(
                    satellite: satellite, observer: observer, minElevation: minimum,
                    days: reportDays, generatedAt: .now
                )
            }.value
            let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            shareURL = try OrbitExportService.temporaryFile(name: "satellite_report_\(base).pdf", data: data)
            shareLabel = "satellite report PDF"
            status = "Prepared analysis, passes, EQX, sky-track, 60-day illumination and 30-day progression for \(satellite.name)."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareIlluminationReport() async {
        guard let satellite = store.selectedSatellite else { status = "Select a satellite first."; return }
        loading = true; defer { loading = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try OrbitExportService.illuminationReportPDF(satellite: satellite, days: 60, generatedAt: .now)
            }.value
            let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            shareURL = try OrbitExportService.temporaryFile(name: "illumination_\(base).pdf", data: data)
            shareLabel = "illumination PDF"
            status = "Prepared the 60-day illumination raster."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareProgressionReport() async {
        guard let satellite = store.selectedSatellite else { status = "Select a satellite first."; return }
        let observer = store.preferences.observer
        let minimum = store.preferences.minElevation
        loading = true; defer { loading = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try OrbitExportService.progressionReportPDF(
                    satellite: satellite, observer: observer, minElevation: minimum, days: 30, generatedAt: .now
                )
            }.value
            let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            shareURL = try OrbitExportService.temporaryFile(name: "progression_\(base).pdf", data: data)
            shareLabel = "progression PDF"
            status = "Prepared the 30-day pass-progression report."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareFavoritesReport() {
        let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
        guard !favorites.isEmpty else { status = "Mark at least one satellite as a favorite first."; return }
        do {
            let data = OrbitExportService.favoritesPassSchedulePDF(
                satellites: favorites,
                observer: store.preferences.observer,
                minElevation: store.preferences.minElevation,
                days: max(3, days)
            )
            shareURL = try OrbitExportService.temporaryFile(name: "favorites_pass_schedule.pdf", data: data)
            shareLabel = "favorites schedule PDF"
            status = "Prepared a chronological schedule across \(favorites.count) favorite satellite(s)."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareSitesReport() {
        guard let satellite = store.selectedSatellite else { status = "Select a satellite first."; return }
        let sites = [store.preferences.observer] + (store.preferences.savedSites ?? [])
        guard sites.count > 1 else { status = "Add at least one secondary site first."; return }
        do {
            let base = satellite.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            let data = OrbitExportService.siteComparisonPDF(
                satellite: satellite,
                sites: sites,
                minElevation: store.preferences.minElevation,
                days: max(3, days)
            )
            shareURL = try OrbitExportService.temporaryFile(name: "site_comparison_\(base).pdf", data: data)
            shareLabel = "site comparison PDF"
            status = "Prepared pass comparison across \(sites.count) site(s)."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareReferenceOrbits() {
        let sats: [SatelliteRecord]
        if referenceFavorites {
            sats = store.satellites.filter { store.preferences.favorites.contains($0.id) }
            guard !sats.isEmpty else { status = "Mark at least one satellite as a favorite first."; return }
        } else {
            guard let selected = store.selectedSatellite else { status = "Select a satellite first."; return }
            sats = [selected]
        }
        do {
            let base = referenceFavorites ? "favorites" : sats[0].name.replacingOccurrences(of:" ",with:"_").replacingOccurrences(of:"/",with:"-")
            let data = OrbitExportService.referenceOrbitsPDF(satellites: sats, observer: store.preferences.observer, days: referenceDays)
            shareURL = try OrbitExportService.temporaryFile(name: "reference_orbits_\(base).pdf", data: data)
            shareLabel = "reference-orbits PDF"
            status = "Prepared \(referenceDays)-day OSCARLOCATOR reference orbits for \(sats.count) satellite(s)."
        } catch { status = error.localizedDescription }
    }

    @MainActor private func prepareCompactListing() {
        guard let sat=store.selectedSatellite,!passes.isEmpty else { status="No passes to export."; return }
        do {
            let base=sat.name.replacingOccurrences(of:" ",with:"_").replacingOccurrences(of:"/",with:"-")
            shareURL=try OrbitExportService.temporaryTextFile(name:"aoslos_\(base).csv",text:OrbitExportService.compactAOSLOSCSV(passes,satellite:sat))
            shareLabel="AOS/LOS CSV"; status="Compact pass listing prepared."
        } catch { status=error.localizedDescription }
    }

    @MainActor private func prepareEquatorCrossings() async {
        guard let sat=store.selectedSatellite else { return }
        do {
            let ascending=store.preferences.observer.latitude>=0
            let crossings=try OrbitPredictor.equatorCrossings(sat,from:.now,to:Date().addingTimeInterval(Double(days)*86400),ascending:ascending)
            let base=sat.name.replacingOccurrences(of:" ",with:"_").replacingOccurrences(of:"/",with:"-")
            shareURL=try OrbitExportService.temporaryTextFile(name:"equator_crossings_\(base).csv",text:OrbitExportService.equatorCrossingsCSV(crossings,satellite:sat))
            shareLabel="equator-crossing CSV"; status="Prepared \(crossings.count) \(ascending ? "ascending" : "descending") equator crossings."
        } catch { status=error.localizedDescription }
    }

    @MainActor private func prepareSteppedListing() {
        guard let sat=store.selectedSatellite else { return }
        do {
            let base=sat.name.replacingOccurrences(of:" ",with:"_").replacingOccurrences(of:"/",with:"-")
            let csv=try OrbitExportService.steppedListingCSV(satellite:sat,observer:store.preferences.observer,hours:6,stepSeconds:60)
            shareURL=try OrbitExportService.temporaryTextFile(name:"position_listing_\(base).csv",text:csv)
            shareLabel="position listing CSV"; status="Prepared six-hour one-minute ephemeris listing."
        } catch { status=error.localizedDescription }
    }

    @MainActor private func prepareTwoSiteListing(_ second: ObserverSite) {
        guard let sat=store.selectedSatellite else { return }
        do {
            let base=sat.name.replacingOccurrences(of:" ",with:"_").replacingOccurrences(of:"/",with:"-")
            let csv=try OrbitExportService.twoSiteListingCSV(satellite:sat,first:store.preferences.observer,second:second,hours:3,stepSeconds:60)
            shareURL=try OrbitExportService.temporaryTextFile(name:"two_site_listing_\(base).csv",text:csv)
            shareLabel="two-site listing CSV"; status="Prepared three-hour two-observer ephemeris listing."
        } catch { status=error.localizedDescription }
    }

    @MainActor private func schedule(_ pass: PredictedPass) async {
        guard let sat = store.selectedSatellite else { return }
        let lead = store.preferences.passAlarmLeadMinutes ?? 10
        do {
            try await PassAlarmService.schedule(pass: pass, satellite: sat, observer: store.preferences.observer, leadMinutes: lead)
            status = "Alarm scheduled \(lead) minute(s) before \(ODFormat.utcShort.string(from: pass.aos))."
        } catch { status = error.localizedDescription }
    }
}

// MARK: - Manual catalog editors

struct ManualSatelliteEditor: View {
    @EnvironmentObject private var store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    let record: SatelliteRecord?

    @State private var name: String
    @State private var norad: String
    @State private var designator: String
    @State private var epoch: Date
    @State private var inclination: String
    @State private var raan: String
    @State private var eccentricity: String
    @State private var argp: String
    @State private var meanAnomaly: String
    @State private var meanMotion: String
    @State private var bstar: String
    @State private var error = ""

    init(record: SatelliteRecord?) {
        self.record = record
        _name = State(initialValue: record?.name ?? "")
        _norad = State(initialValue: record.map { String($0.id) } ?? "")
        _designator = State(initialValue: record?.internationalDesignator ?? "")
        _epoch = State(initialValue: record?.epoch ?? .now)
        _inclination = State(initialValue: record.map { String($0.inclinationDeg) } ?? "")
        _raan = State(initialValue: record.map { String($0.raanDeg) } ?? "")
        _eccentricity = State(initialValue: record.map { String($0.eccentricity) } ?? "")
        _argp = State(initialValue: record.map { String($0.argumentOfPerigeeDeg) } ?? "")
        _meanAnomaly = State(initialValue: record.map { String($0.meanAnomalyDeg) } ?? "")
        _meanMotion = State(initialValue: record.map { String($0.meanMotionRevPerDay) } ?? "")
        _bstar = State(initialValue: record.map { String($0.bstar) } ?? "0")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name).textFieldStyle(.odField)
                    TextField("NORAD / synthetic ID", text: $norad).keyboardType(.numberPad).textFieldStyle(.odField)
                    TextField("International designator (optional)", text: $designator).textInputAutocapitalization(.characters).textFieldStyle(.odField)
                    DatePicker("Epoch (UTC instant)", selection: $epoch)
                }
                Section("Mean elements") {
                    field("Inclination (deg)", $inclination)
                    field("RAAN (deg)", $raan)
                    field("Eccentricity", $eccentricity)
                    field("Argument of perigee (deg)", $argp)
                    field("Mean anomaly (deg)", $meanAnomaly)
                    field("Mean motion (rev/day)", $meanMotion)
                    field("BSTAR", $bstar)
                }
                if !error.isEmpty { Text(error).foregroundStyle(ODTheme.warning) }
            }
            .navigationTitle(record == nil ? "Add Manual Satellite" : "Edit Manual Satellite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func field(_ label: String, _ binding: Binding<String>) -> some View {
        TextField(label, text: binding).keyboardType(.numbersAndPunctuation).textFieldStyle(.odField)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let n = UInt(norad),
              let inc = Double(inclination), let node = Double(raan),
              let ecc = Double(eccentricity), let ap = Double(argp),
              let ma = Double(meanAnomaly), let mm = Double(meanMotion), mm > 0,
              let bs = Double(bstar), ecc >= 0, ecc < 1 else {
            error = "Enter a name, numeric ID, valid mean elements, 0 ≤ eccentricity < 1, and mean motion > 0."
            return
        }
        if let existing = store.satellites.first(where: { $0.id == n }), existing.id != record?.id {
            error = "NORAD / synthetic ID \(n) already exists as \(existing.name). Choose a unique ID."
            return
        }
        let def = ManualSatelliteDefinition(name: name.trimmingCharacters(in: .whitespacesAndNewlines), norad: n, internationalDesignator: designator.trimmingCharacters(in: .whitespacesAndNewlines), epoch: epoch, inclinationDeg: inc, raanDeg: node, eccentricity: ecc, argumentOfPerigeeDeg: ap, meanAnomalyDeg: ma, meanMotionRevPerDay: mm, bstar: bs)
        store.saveManualSatellite(def, replacing: record?.id)
        dismiss()
    }
}

struct ManualTransponderManager: View {
    @EnvironmentObject private var store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    let satellite: SatelliteRecord
    @State private var description = ""
    @State private var downlink = ""
    @State private var downlinkHigh = ""
    @State private var uplink = ""
    @State private var uplinkHigh = ""
    @State private var mode = "FM"
    @State private var invert = false
    @State private var error = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved manual transponders") {
                    if store.manualTransponders(for: satellite.id).isEmpty {
                        Text("None").foregroundStyle(ODTheme.muted)
                    }
                    ForEach(store.manualTransponders(for: satellite.id)) { tx in
                        VStack(alignment: .leading) {
                            Text(tx.description.isEmpty ? tx.kind : tx.description)
                            Text("\(ODFormat.frequency(tx.downlinkCenter)) • \(tx.kind)").font(.caption).foregroundStyle(ODTheme.muted)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.deleteManualTransponder(id: tx.id, from: satellite.id) }
                        }
                    }
                }
                Section("Add transponder") {
                    TextField("Description", text: $description).textFieldStyle(.odField)
                    TextField("Downlink low/center MHz", text: $downlink).keyboardType(.decimalPad).textFieldStyle(.odField)
                    TextField("Downlink high MHz (optional)", text: $downlinkHigh).keyboardType(.decimalPad).textFieldStyle(.odField)
                    TextField("Uplink low/center MHz (optional)", text: $uplink).keyboardType(.decimalPad).textFieldStyle(.odField)
                    TextField("Uplink high MHz (optional)", text: $uplinkHigh).keyboardType(.decimalPad).textFieldStyle(.odField)
                    TextField("Mode", text: $mode).textFieldStyle(.odField)
                    Toggle("Inverting linear transponder", isOn: $invert)
                    Button("Add Manual Transponder") { add() }
                    if !error.isEmpty { Text(error).foregroundStyle(ODTheme.warning) }
                }
            }
            .navigationTitle("\(satellite.name) Transponders")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func mhz(_ text: String) -> Int64 {
        guard let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 else { return 0 }
        return Int64((v * 1_000_000).rounded())
    }

    private func add() {
        let dl = mhz(downlink)
        guard dl > 0 else { error = "A downlink frequency is required."; return }
        let dlhi = max(dl, mhz(downlinkHigh))
        let ul = mhz(uplink)
        let ulhi = ul > 0 ? max(ul, mhz(uplinkHigh)) : 0
        let tx = TransponderRecord(id: "manual-\(satellite.id)-\(UUID().uuidString)", description: description, downlinkLow: dl, downlinkHigh: dlhi, uplinkLow: ul, uplinkHigh: ulhi, mode: mode, invert: invert, type: "Manual", baud: 0, service: "Amateur")
        store.addManualTransponder(tx, to: satellite.id)
        description = ""; downlink = ""; downlinkHigh = ""; uplink = ""; uplinkHigh = ""; error = ""
    }
}
