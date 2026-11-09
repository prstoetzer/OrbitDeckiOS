import SwiftUI
import Charts
import UIKit
import CoreLocation
import UserNotifications
import UniformTypeIdentifiers

// MARK: - 3D-look globe

private enum GlobeViewMode: String, CaseIterable, Identifiable {
    case satellite = "Follow satellite", station = "Over station", north = "North pole", south = "South pole", free = "Free"
    var id: String { rawValue }
    /// Short label so the segmented control fits without truncation.
    var short: String {
        switch self {
        case .satellite: "Follow"
        case .station: "Station"
        case .north: "North"
        case .south: "South"
        case .free: "Free"
        }
    }
}

struct GlobeView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var mode: GlobeViewMode = .satellite
    // Playback time is derived from the TimelineView clock rather than a manual
    // async loop: `frozenOffset` is the minutes-from-now shown while paused, and
    // while playing the live offset grows from `playStartOffset` by real elapsed
    // time × speed. This avoids the @State-capture staleness of a Task loop.
    @State private var frozenOffset: Double = 0
    @State private var playStartWall: Date?
    @State private var playStartOffset: Double = 0
    @State private var freeLat = 20.0
    @State private var freeLon = 0.0
    @State private var isPlaying = false
    @State private var playbackSpeed = 60.0
    @State private var dragBaseLat: Double?
    @State private var dragBaseLon: Double?
    /// Second station (grid or lat,lon) whose horizon circle is drawn so the
    /// mutual-visibility overlap with the QTH circle is visible.
    @AppStorage("globe.dxGrid") private var dxGrid = ""

    private var dxLocation: LatLon? {
        let t = dxGrid.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (GeoFormats.gridCenter(t) ?? FeatureEngine.parseLocation(t))
    }

    /// Human-readable scrub offset, e.g. "Showing now", "+45 min from now",
    /// "−2 h 30 min from now".
    private func offsetLabel(_ off: Double) -> String {
        if abs(off) < 0.5 { return "Showing now" }
        let sign = off >= 0 ? "+" : "−"
        let total = Int(abs(off).rounded())
        let h = total / 60, m = total % 60
        let magnitude = h > 0 ? "\(h) h \(m) min" : "\(m) min"
        return "\(sign)\(magnitude) from now"
    }

    private func effectiveOffset(_ date: Date) -> Double {
        guard isPlaying, let start = playStartWall else { return frozenOffset }
        return min(1440, playStartOffset + date.timeIntervalSince(start) * playbackSpeed / 60.0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("View", selection: $mode) {
                    ForEach(GlobeViewMode.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    Button {
                        if isPlaying {
                            frozenOffset = effectiveOffset(Date())
                            isPlaying = false
                            playStartWall = nil
                        } else {
                            playStartOffset = frozenOffset
                            playStartWall = Date()
                            isPlaying = true
                        }
                    } label: {
                        Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button("Now") { frozenOffset = 0; isPlaying = false; playStartWall = nil }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                    Picker("Speed", selection: $playbackSpeed) {
                        Text("10×").tag(10.0)
                        Text("60×").tag(60.0)
                        Text("300×").tag(300.0)
                        Text("1800×").tag(1800.0)
                    }
                    .pickerStyle(.menu)
                    .tint(ODTheme.accent)
                    .onChange(of: playbackSpeed) {
                        // Re-anchor so the speed change is continuous, not a jump.
                        if isPlaying {
                            playStartOffset = effectiveOffset(Date())
                            playStartWall = Date()
                        }
                    }
                }

                // Scrub time directly. Grabbing the slider stops playback and pins
                // the shown moment; the thumb starts from wherever playback left off.
                VStack(spacing: 2) {
                    Slider(value: $frozenOffset.snapping(to: 0, within: 10), in: -1440...1440, step: 1) { editing in
                        if editing && isPlaying {
                            frozenOffset = effectiveOffset(Date())
                            isPlaying = false
                            playStartWall = nil
                        }
                    }
                    .tint(ODTheme.accent)
                    HStack {
                        Text("−24 h").font(.caption2).foregroundStyle(ODTheme.muted)
                        Spacer()
                        Text("now").font(.caption2).foregroundStyle(ODTheme.muted)
                        Spacer()
                        Text("+24 h").font(.caption2).foregroundStyle(ODTheme.muted)
                    }
                }

                HStack(spacing: 8) {
                    Text("DX grid").font(.subheadline).foregroundStyle(ODTheme.muted)
                    TextField("e.g. JO01 or 51.5,-0.1", text: $dxGrid)
                        .textFieldStyle(.odField)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    if !dxGrid.isEmpty {
                        Image(systemName: dxLocation == nil ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(dxLocation == nil ? ODTheme.warning : ODTheme.good)
                    }
                }

                TimelineView(isPlaying ? .periodic(from: .now, by: 0.5) : .periodic(from: .now, by: 2)) { context in
                    let off = effectiveOffset(context.date)
                    VStack(spacing: 8) {
                        Text(offsetLabel(off))
                            .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        globe(at: context.date.addingTimeInterval(off * 60))
                            .frame(minHeight: 420)
                            .odPanel()
                            .gesture(freeDragGesture, including: mode == .free ? .all : .none)
                        globeInfoRow(at: context.date.addingTimeInterval(off * 60))
                    }
                }
                Text(mode == .free
                     ? "Free view: drag the globe to rotate. Play animates time; ‘Now’ resets. Coastlines, favorite satellites (labeled), the QTH marker and day/night shading are always shown."
                     : "Orthographic ‘view from space’ globe with coastlines, the selected satellite’s ground track and footprint, labeled favorite satellites, QTH marker and day/night shading. Play animates time.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }.padding()
        }
    }

    private var freeDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragBaseLat == nil { dragBaseLat = freeLat; dragBaseLon = freeLon }
                let baseLat = dragBaseLat ?? freeLat
                let baseLon = dragBaseLon ?? freeLon
                freeLat = min(90, max(-90, baseLat + Double(value.translation.height) * 0.4))
                var lon = baseLon - Double(value.translation.width) * 0.4
                while lon > 180 { lon -= 360 }
                while lon < -180 { lon += 360 }
                freeLon = lon
            }
            .onEnded { _ in dragBaseLat = nil; dragBaseLon = nil }
    }

    @ViewBuilder private func globe(at date: Date) -> some View {
        if let sat = store.selectedSatellite, let look = try? OrbitPredictor.look(sat, observer:store.preferences.observer, at:date) {
            let center = centerPoint(look:look)
            let favorites = store.satellites.filter { store.preferences.favorites.contains($0.id) }
            let palette = store.satellitePalette
            let satColor = palette.color(sat.id)
            let minElevation = store.preferences.minElevation
            Canvas { context, size in
                let r=min(size.width,size.height)/2-24, c=CGPoint(x:size.width/2,y:size.height/2)
                context.fill(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:2*r,height:2*r)), with:.color(ODTheme.globeOcean))
                context.stroke(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:2*r,height:2*r)), with:.color(ODTheme.grid), lineWidth:1.5)
                drawNight(context:&context,size:size,c:c,r:r,center:center,date:date)
                drawGraticule(context:&context,c:c,r:r,center:center)
                drawCoastlines(context:&context,c:c,r:r,center:center)
                if let p=project(lat:store.preferences.observer.latitude,lon:store.preferences.observer.longitude,center:center,c:c,r:r) { context.draw(Text("★").foregroundStyle(ODTheme.warning).font(.title3),at:p) }
                drawTrack(context:&context,satellite:sat,date:date,center:center,c:c,r:r,color:satColor)
                drawFootprint(context:&context,lat:look.subLatitude,lon:look.subLongitude,alt:look.altitudeKm,center:center,c:c,r:r,color:satColor)
                // Dashed ring at the operator's minimum elevation (the usable footprint).
                if minElevation > 0 {
                    drawFootprint(context:&context,lat:look.subLatitude,lon:look.subLongitude,alt:look.altitudeKm,center:center,c:c,r:r,color:satColor,elevation:minElevation)
                }
                // DX footprint: the horizon circle around each station is the set of
                // sub-points from which the satellite (at its current altitude) is up
                // there, so the lens where the QTH and DX circles overlap is where the
                // sub-point must be for a mutual QSO.
                if let dx = dxLocation {
                    let ang = FootprintGeometry.centralAngle(altitudeKm: max(1, look.altitudeKm))
                    let obs = store.preferences.observer
                    for (ll, color) in [((obs.latitude, obs.longitude), ODTheme.warning), ((dx.latitude, dx.longitude), Color.cyan)] {
                        let ring = FootprintGeometry.ring(latitude: ll.0, longitude: ll.1, angleDeg: ang, samples: 90).map { ($0.latitude, $0.longitude) }
                        drawGeoLine(context:&context,points:ring,center:center,c:c,r:r,color:color.opacity(0.85),width:1.2,dash:[3,3])
                    }
                    if let p = project(lat: dx.latitude, lon: dx.longitude, center: center, c: c, r: r) {
                        context.draw(Text("◆").foregroundStyle(Color.cyan).font(.callout), at: p)
                        context.draw(Text("DX").foregroundStyle(Color.cyan).font(.caption2.bold()), at: CGPoint(x: p.x, y: p.y - 13))
                    }
                }
                for fs in favorites where fs.id != sat.id {
                    if let fl = try? OrbitPredictor.look(fs, observer: store.preferences.observer, at: date) {
                        drawSatelliteGlyph(context: &context, satellite: fs, date: date, look: fl,
                                           center: center, c: c, r: r, canvas: size,
                                           color: palette.color(fs.id), size: 12)
                    }
                }
                drawSatelliteGlyph(context: &context, satellite: sat, date: date, look: look,
                                   center: center, c: c, r: r, canvas: size,
                                   color: satColor, size: 15, selected: true)
            }
        } else { ContentUnavailableView("Select a satellite", systemImage:"globe.americas") }
    }

    /// Detailed readout for the moment shown on the globe. Recomputed by the
    /// enclosing TimelineView, so it stays live as time is scrubbed or animated.
    @ViewBuilder private func globeInfoRow(at date: Date) -> some View {
        if let sat = store.selectedSatellite,
           let look = try? OrbitPredictor.look(sat, observer: store.preferences.observer, at: date) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(sat.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Label(look.sunlit ? "Sunlit" : "Eclipse", systemImage: look.sunlit ? "sun.max.fill" : "moon.fill")
                        .font(.caption).foregroundStyle(look.sunlit ? ODTheme.warning : ODTheme.muted)
                }
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    globeStat("Sub-point", String(format: "%.2f°, %.2f°", look.subLatitude, look.subLongitude))
                    globeStat("Altitude", ODFormat.units(String(format: "%.0f km", look.altitudeKm)))
                    globeStat("Azimuth", String(format: "%.0f°", look.azimuth))
                    globeStat("Elevation", String(format: "%+.1f°", look.elevation))
                    globeStat("Range", ODFormat.units(String(format: "%.0f km", look.rangeKm)))
                    globeStat("Range rate", ODFormat.units(String(format: "%+.2f km/s", look.rangeRateKmS)))
                    globeStat("Footprint", ODFormat.units(String(format: "%.0f km", look.footprintRadiusKm * 2)))
                    globeStat("Beta angle", String(format: "%+.1f°", look.betaAngleDeg))
                    if let dx = dxLocation,
                       let dxLook = try? OrbitPredictor.look(sat, observer: ObserverSite(name: "DX", latitude: dx.latitude, longitude: dx.longitude, altitudeMeters: 0), at: date) {
                        globeStat("DX elevation", String(format: "%+.1f°", dxLook.elevation))
                        globeStat("Mutual", look.elevation > 0 && dxLook.elevation > 0 ? "Yes" : "No")
                    }
                }
            }
            .padding(10)
            .odPanel()
        }
    }

    @ViewBuilder private func globeStat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(ODTheme.muted)
            Spacer(minLength: 4)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    /// Compressed altitude as a fraction of Earth radius to offset a satellite
    /// glyph outward from its sub-point. Keeps LEO tight while lifting MEO/GEO
    /// visibly, capped so high orbits don't fly off the disc.
    private func altitudeFraction(_ altitudeKm: Double) -> Double {
        0.16 * altitudeKm / (altitudeKm + 2500)
    }

    /// Draw a small heading arrow for a satellite at its sub-point, raised outward
    /// by its (scaled) altitude, with a faint tether to the ground point and a
    /// label. Orthographic projection means the raised position is the surface
    /// offset vector scaled by (1 + altitude fraction). The arrow points the
    /// satellite's direction of travel (sampled ~1 min ahead). The selected
    /// satellite gets a white halo and a bolder label rather than another hue.
    private func drawSatelliteGlyph(context: inout GraphicsContext, satellite: SatelliteRecord, date: Date, look: LiveLook,
                                    center: (Double, Double), c: CGPoint, r: Double, canvas: CGSize,
                                    color: Color, size: CGFloat, selected: Bool = false) {
        guard let surface = project(lat: look.subLatitude, lon: look.subLongitude, center: center, c: c, r: r) else { return }
        let scale = 1 + altitudeFraction(look.altitudeKm)
        let glyph = CGPoint(x: c.x + (surface.x - c.x) * scale, y: c.y + (surface.y - c.y) * scale)
        var tether = Path(); tether.move(to: surface); tether.addLine(to: glyph)
        context.stroke(tether, with: .color(color.opacity(0.4)), lineWidth: 0.7)
        context.fill(Path(ellipseIn: CGRect(x: surface.x - 1.5, y: surface.y - 1.5, width: 3, height: 3)),
                     with: .color(color.opacity(0.5)))

        // Direction of travel from the period-adaptive ground bearing, projected as
        // a fixed 0.5° geodesic step from the sub-point. This never collapses to a
        // sub-pixel delta at HEO apogee the way a fixed 60 s look-ahead did.
        var angle: Double?
        if let bearing = OrbitPredictor.groundBearing(satellite, observer: store.preferences.observer, at: date) {
            let step = destination(lat: look.subLatitude, lon: look.subLongitude, distanceDeg: 0.5, bearingDeg: bearing)
            if let aheadSurface = project(lat: step.0, lon: step.1, center: center, c: c, r: r) {
                let ag = CGPoint(x: c.x + (aheadSurface.x - c.x) * scale, y: c.y + (aheadSurface.y - c.y) * scale)
                if hypot(ag.x - glyph.x, ag.y - glyph.y) > 0.3 { angle = atan2(ag.y - glyph.y, ag.x - glyph.x) }
            }
        }
        if selected {
            let h = size * 0.7
            context.fill(Path(ellipseIn: CGRect(x: glyph.x - h, y: glyph.y - h, width: 2 * h, height: 2 * h)),
                         with: .color(.white.opacity(0.18)))
        }
        if let angle {
            drawHeadingArrow(&context, at: glyph, angle: angle, color: color, size: size * 0.5)
        } else {
            let d = size * 0.32
            context.fill(Path(ellipseIn: CGRect(x: glyph.x - d, y: glyph.y - d, width: 2 * d, height: 2 * d)), with: .color(color))
        }
        let label = context.resolve(Text(satellite.name)
            .font(.system(size: selected ? 10 : 8, weight: selected ? .bold : .semibold))
            .foregroundStyle(color.opacity(selected ? 1 : 0.9)))
        context.draw(label, at: Self.labelPosition(glyph: glyph, offset: size * 0.9,
                                                   label: label.measure(in: CGSize(width: 240, height: 40)),
                                                   canvas: canvas, headingAngle: angle))
    }

    /// Where to center a glyph's label so it stays inside the canvas: above the
    /// glyph normally, below it near the top edge or when the arrow points up the
    /// screen (where it would sit on the label), and clamped horizontally.
    nonisolated static func labelPosition(glyph: CGPoint, offset: CGFloat, label: CGSize, canvas: CGSize,
                                          headingAngle: Double?) -> CGPoint {
        let margin: CGFloat = 2
        let headingUp = headingAngle.map { sin($0) < -0.7 } ?? false
        var y = glyph.y - offset
        if headingUp || y - label.height / 2 < margin { y = glyph.y + offset }
        y = min(max(y, label.height / 2 + margin), canvas.height - label.height / 2 - margin)
        let halfW = min(label.width / 2, canvas.width / 2 - margin)
        let x = min(max(glyph.x, halfW + margin), canvas.width - halfW - margin)
        return CGPoint(x: x, y: y)
    }

    private func centerPoint(look:LiveLook)->(Double,Double) { switch mode { case .satellite:return(look.subLatitude,look.subLongitude);case .station:return(store.preferences.observer.latitude,store.preferences.observer.longitude);case .north:return(90,0);case .south:return(-90,0);case .free:return(freeLat,freeLon) } }
    private func project(lat:Double,lon:Double,center:(Double,Double),c:CGPoint,r:Double)->CGPoint? { let la=lat*Double.pi/180,lo=lon*Double.pi/180,cl=center.0*Double.pi/180,co=center.1*Double.pi/180; let cosc=sin(cl)*sin(la)+cos(cl)*cos(la)*cos(lo-co); guard cosc>=0 else{return nil}; let x=cos(la)*sin(lo-co),y=cos(cl)*sin(la)-sin(cl)*cos(la)*cos(lo-co); return CGPoint(x:c.x+r*x,y:c.y-r*y) }
    private func drawGraticule(context:inout GraphicsContext,c:CGPoint,r:Double,center:(Double,Double)) { for lat in stride(from:-60.0,through:60.0,by:30){ drawGeoLine(context:&context,points:stride(from:-180.0,through:180.0,by:4).map{(lat,$0)},center:center,c:c,r:r,color:ODTheme.grid.opacity(0.7),width:0.6) }; for lon in stride(from:-180.0,through:180.0,by:30){drawGeoLine(context:&context,points:stride(from:-90.0,through:90.0,by:4).map{($0,lon)},center:center,c:c,r:r,color:ODTheme.grid.opacity(0.7),width:0.6)} }
    private func drawCoastlines(context:inout GraphicsContext,c:CGPoint,r:Double,center:(Double,Double)) { for polyline in WorldMapData.coastlines { drawGeoLine(context:&context,points:polyline.map { ($0.1,$0.0) },center:center,c:c,r:r,color:.white.opacity(0.55),width:1.0) } }
    private func drawGeoLine(context:inout GraphicsContext,points:[(Double,Double)],center:(Double,Double),c:CGPoint,r:Double,color:Color,width:Double,dash:[CGFloat]=[]){ let style=StrokeStyle(lineWidth:width,dash:dash); var p=Path(),started=false; for ll in points { if let q=project(lat:ll.0,lon:ll.1,center:center,c:c,r:r){ if started{p.addLine(to:q)}else{p.move(to:q);started=true} } else { if started{context.stroke(p,with:.color(color),style:style);p=Path();started=false} } }; if started{context.stroke(p,with:.color(color),style:style)} }
    private func drawTrack(context:inout GraphicsContext,satellite:SatelliteRecord,date:Date,center:(Double,Double),c:CGPoint,r:Double,color:Color){ let period=max(60,satellite.periodMinutes*60); let points=(0...120).compactMap{i->(Double,Double)? in let t=date.addingTimeInterval(-period/2+period*Double(i)/120); guard let l=try? OrbitPredictor.look(satellite,observer:store.preferences.observer,at:t)else{return nil};return(l.subLatitude,l.subLongitude)}; drawGeoLine(context:&context,points:points,center:center,c:c,r:r,color:color,width:1.8) }
    /// Footprint ring at `elevation` (0° = horizon footprint, solid; above 0° =
    /// the operator's minimum-elevation ring, dashed). See `FootprintGeometry`.
    private func drawFootprint(context:inout GraphicsContext,lat:Double,lon:Double,alt:Double,center:(Double,Double),c:CGPoint,r:Double,color:Color,elevation:Double=0){ let ang=FootprintGeometry.centralAngle(altitudeKm:max(1,alt),elevation:elevation); let pts=stride(from:0.0,through:360.0,by:5).map{destination(lat:lat,lon:lon,distanceDeg:ang,bearingDeg:$0)}; drawGeoLine(context:&context,points:pts,center:center,c:c,r:r,color:color.opacity(elevation>0 ? 0.9 : 0.8),width:elevation>0 ? 1.0 : 1.1,dash:elevation>0 ? [5,4] : []) }
    private func destination(lat:Double,lon:Double,distanceDeg:Double,bearingDeg:Double)->(Double,Double){let p1=lat*Double.pi/180,l1=lon*Double.pi/180,d=distanceDeg*Double.pi/180,b=bearingDeg*Double.pi/180;let p2=asin(sin(p1)*cos(d)+cos(p1)*sin(d)*cos(b));let l2=l1+atan2(sin(b)*sin(d)*cos(p1),cos(d)-sin(p1)*sin(p2));return(p2*180/Double.pi,((l2*180/Double.pi+540).truncatingRemainder(dividingBy:360))-180)}
    private func drawNight(context: inout GraphicsContext, size: CGSize, c: CGPoint, r: Double, center: (Double, Double), date: Date) {
        let subSun = subsolarPoint(date)
        let step = max(5.0, r / 28.0)
        let cl = center.0 * Double.pi / 180.0
        let co = center.1 * Double.pi / 180.0
        let east = (-sin(co), cos(co), 0.0)
        let north = (-sin(cl) * cos(co), -sin(cl) * sin(co), cos(cl))
        let cen = (cos(cl) * cos(co), cos(cl) * sin(co), sin(cl))
        for y in stride(from: c.y - r, through: c.y + r, by: step) {
            for x in stride(from: c.x - r, through: c.x + r, by: step) {
                let dx = (x - c.x) / r
                let dy = -(y - c.y) / r
                let rr = dx * dx + dy * dy
                guard rr <= 1 else { continue }
                let z = sqrt(max(0, 1 - rr))
                let px = dx * east.0 + dy * north.0 + z * cen.0
                let py = dx * east.1 + dy * north.1 + z * cen.1
                let pz = dx * east.2 + dy * north.2 + z * cen.2
                let lat = asin(pz) * 180 / Double.pi
                let lon = atan2(py, px) * 180 / Double.pi
                if angular(lat, lon, subSun.0, subSun.1) > 90 {
                    context.fill(Path(ellipseIn: CGRect(x: x-step/2, y: y-step/2, width: step, height: step)), with: .color(.black.opacity(0.16)))
                }
            }
        }
    }

    private func subsolarPoint(_ date: Date) -> (Double, Double) {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let n = jd - 2451545.0
        let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n) * Double.pi / 180
        let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2*g)) * Double.pi / 180
        let eps = (23.439 - 0.0000004 * n) * Double.pi / 180
        let ra = atan2(cos(eps) * sin(lambda), cos(lambda)) * 180 / Double.pi
        let dec = asin(sin(eps) * sin(lambda)) * 180 / Double.pi
        let t = (jd - 2451545.0) / 36525.0
        let gmst = (280.46061837 + 360.98564736629 * (jd - 2451545.0) + 0.000387933*t*t - t*t*t/38710000.0).truncatingRemainder(dividingBy: 360)
        var lon = ra - gmst
        while lon > 180 { lon -= 360 }
        while lon < -180 { lon += 360 }
        return (dec, lon)
    }

    private func angular(_ a:Double,_ b:Double,_ c:Double,_ d:Double)->Double{let p1=a*Double.pi/180,p2=c*Double.pi/180,dl=(d-b)*Double.pi/180;return acos(max(-1,min(1,sin(p1)*sin(p2)+cos(p1)*cos(p2)*cos(dl))))*180/Double.pi}
}

// Legacy ToolsView removed — the Tools screen is DeepToolsView (single-column,
// works inside the RootView split-view detail).

// MARK: - Graphing calculator

struct GraphCalcView: View {
    @State private var f1="sin(x)"
    @State private var f2=""
    @State private var xmin="-180"
    @State private var xmax="180"
    @State private var ymin="-2"
    @State private var ymax="2"
    @State private var autoY=true
    @State private var showTable=false
    @State private var traceX: Double?
    @State private var intA = "0"
    @State private var intB = "90"
    @State private var importedPoints: [(x: Double, y: Double)] = []
    @State private var importing = false
    @State private var importStatus = ""
    /// Sampled traces and the analysis (zeros, integrals, intersections), recomputed only
    /// when the functions, window or integral bounds change — not on every body pass
    /// (a trace drag re-renders the view many times a second).
    @State private var cache = GraphCache()
    private let engine=GraphCalculatorEngine()

    private struct GraphInputs: Equatable {
        var f1: String, f2: String, lo: Double, hi: Double, intA: String, intB: String
    }
    private struct GraphCache {
        var inputs: GraphInputs?
        var a: [GraphPoint] = []
        var b: [GraphPoint] = []
        var roots: [Double] = []
        var area = 0.0
        var intersections: [Double] = []
        var definite: Double?
    }
    private var inputs: GraphInputs { GraphInputs(f1: f1, f2: f2, lo: lo, hi: hi, intA: intA, intB: intB) }
    private var lo: Double { Double(xmin) ?? -180 }
    private var hi: Double { max(lo + 0.001, Double(xmax) ?? 180) }
    private var hasF2: Bool { !f2.trimmingCharacters(in: .whitespaces).isEmpty }
    private func yAt(_ expr: String, _ x: Double) -> Double? {
        guard !expr.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let y = try? SafeMathEvaluator().evaluate(expr, variables: ["x": x], degrees: true)
        return y.flatMap { $0.isFinite ? $0 : nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack { Text("y ="); TextField("sin(x)", text: $f1).textFieldStyle(.odField); Text("y ="); TextField("optional second trace", text: $f2).textFieldStyle(.odField) }
                HStack {
                    Text("x"); TextField("min", text: $xmin).textFieldStyle(.odField)
                    Text("to"); TextField("max", text: $xmax).textFieldStyle(.odField)
                    Toggle("Auto y", isOn: $autoY)
                    if !autoY { TextField("y min", text: $ymin).textFieldStyle(.odField); TextField("y max", text: $ymax).textFieldStyle(.odField) }
                }
                HStack(spacing: 8) {
                    Button { zoom(0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { zoom(1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { pan(-0.25) } label: { Image(systemName: "arrow.left") }
                    Button { pan(0.25) } label: { Image(systemName: "arrow.right") }
                    Button("Reset") { xmin = "-180"; xmax = "180"; autoY = true }
                    Spacer()
                }
                .buttonStyle(.bordered).font(.caption)
                HStack {
                    Picker("View", selection: $showTable) { Text("Plot").tag(false); Text("Table").tag(true) }
                        .pickerStyle(.segmented).frame(width: 150)
                    Spacer()
                    ShareLink(item: csvText()) { Label("CSV", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered).font(.caption)
                }
                if showTable {
                    tableView.odPanel()
                } else {
                    graph.frame(minHeight: 380).odPanel()
                    if let tx = traceX {
                        let y1 = yAt(f1, tx), y2 = yAt(f2, tx)
                        HStack {
                            Text(String(format: "x = %.4g", tx))
                            if let y1 { Text(String(format: "· y₁ = %.5g", y1)).foregroundStyle(ODTheme.good) }
                            if let y2 { Text(String(format: "· y₂ = %.5g", y2)).foregroundStyle(ODTheme.accent) }
                            if let d = derivative(f1, at: tx) { Text(String(format: "· dy₁/dx = %.5g", d)) }
                            Spacer()
                            Button("Clear trace") { traceX = nil }.font(.caption2)
                        }
                        .font(.caption.monospaced())
                    }
                    analysis
                }
                Text("Degrees mode. Drag on the plot to trace (shows dy₁/dx). Zeros and y₁ = y₂ intersections are refined by bisection; ∫ from a to b uses Simpson's rule. Import a two-column x,y CSV to plot data points. Evaluator supports x, pi/e and the same functions as the scientific calculator (trig/inverse/hyperbolic, ln/log/log2/exp, sqrt/cbrt, RF/orbit helpers, metric prefixes). Undefined points break the trace.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            .padding()
        }
        .task(id: inputs) {
            // Debounce typing; the first computation runs immediately.
            if cache.inputs != nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            recompute()
        }
    }

    private func recompute() {
        var c = GraphCache(inputs: inputs)
        c.a = engine.sample(f1, xmin: lo, xmax: hi)
        c.b = hasF2 ? engine.sample(f2, xmin: lo, xmax: hi) : []
        c.roots = zeros(of: c.a)
        c.area = integral(of: c.a)
        c.intersections = hasF2 ? intersections() : []
        c.definite = simpson(f1, Double(intA) ?? .nan, Double(intB) ?? .nan)
        cache = c
    }

    @ViewBuilder private var graph: some View {
        let a = cache.a, b = cache.b, roots = cache.roots
        Chart {
            ForEach(a) { p in if let y = p.y { LineMark(x: .value("x", p.x), y: .value("y", y)).foregroundStyle(ODTheme.good) } }
            ForEach(b) { p in if let y = p.y { LineMark(x: .value("x", p.x), y: .value("y2", y)).foregroundStyle(ODTheme.accent) } }
            ForEach(Array(importedPoints.enumerated()), id: \.offset) { _, p in
                PointMark(x: .value("x", p.x), y: .value("data", p.y)).foregroundStyle(ODTheme.warning).symbolSize(18)
            }
            ForEach(Array(roots.enumerated()), id: \.offset) { _, rx in
                RuleMark(x: .value("root", rx)).foregroundStyle(ODTheme.warning.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            if let tx = traceX {
                RuleMark(x: .value("trace", tx)).foregroundStyle(ODTheme.muted).lineStyle(StrokeStyle(lineWidth: 1))
                if let y1 = yAt(f1, tx) { PointMark(x: .value("x", tx), y: .value("y", y1)).foregroundStyle(ODTheme.good) }
                if let y2 = yAt(f2, tx) { PointMark(x: .value("x", tx), y: .value("y2", y2)).foregroundStyle(ODTheme.accent) }
            }
        }
        .chartXScale(domain: lo...hi)
        .modifier(OptionalYDomain(enabled: !autoY, lo: Double(ymin) ?? -2, hi: Double(ymax) ?? 2))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let originX = geo[proxy.plotAreaFrame].origin.x
                        if let x: Double = proxy.value(atX: value.location.x - originX) {
                            traceX = min(hi, max(lo, x))
                        }
                    })
            }
        }
        .padding()
    }

    @ViewBuilder private var tableView: some View {
        let rows = tableRows()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("x").frame(width: 90, alignment: .leading)
                Text("y₁").frame(maxWidth: .infinity, alignment: .leading)
                if hasF2 { Text("y₂").frame(maxWidth: .infinity, alignment: .leading) }
            }.font(.caption.bold().monospaced())
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack {
                    Text(String(format: "%.4g", r.0)).frame(width: 90, alignment: .leading)
                    Text(r.1.map { String(format: "%.5g", $0) } ?? "—").frame(maxWidth: .infinity, alignment: .leading)
                    if hasF2 { Text(r.2.map { String(format: "%.5g", $0) } ?? "—").frame(maxWidth: .infinity, alignment: .leading) }
                }.font(.caption.monospaced())
            }
        }
        .padding()
    }

    /// ~24 evenly spaced rows across the window: (x, y1, y2?).
    private func tableRows() -> [(Double, Double?, Double?)] {
        let n = 24
        return (0...n).map { i in
            let x = lo + (hi - lo) * Double(i) / Double(n)
            return (x, yAt(f1, x), hasF2 ? yAt(f2, x) : nil)
        }
    }

    private func csvText() -> String {
        var out = hasF2 ? "x,y1,y2\n" : "x,y1\n"
        for r in tableRows() {
            let y1 = r.1.map { String(format: "%.8g", $0) } ?? ""
            if hasF2 {
                let y2 = r.2.map { String(format: "%.8g", $0) } ?? ""
                out += String(format: "%.8g,%@,%@\n", r.0, y1, y2)
            } else {
                out += String(format: "%.8g,%@\n", r.0, y1)
            }
        }
        return out
    }

    @ViewBuilder private var analysis: some View {
        let roots = cache.roots, area = cache.area
        VStack(alignment: .leading, spacing: 8) {
            // Stacked: a list of zeros beside the area squeezes both into narrow columns.
            Text(roots.isEmpty ? "No zeros of y₁ in view" : "Zeros of y₁: " + roots.prefix(6).map { String(format: "%.6g", $0) }.joined(separator: ", ") + (roots.count > 6 ? "…" : ""))
            Text(String(format: "∫y₁ dx (view) ≈ %.4g", area))
            if hasF2 {
                let xs = cache.intersections
                Text(xs.isEmpty ? "No intersections of y₁ and y₂ in view"
                     : "y₁ = y₂ at " + xs.prefix(6).map { String(format: "(%.6g, %.6g)", $0, yAt(f1, $0) ?? .nan) }.joined(separator: ", ") + (xs.count > 6 ? "…" : ""))
            }
            HStack {
                Text("∫ from")
                TextField("a", text: $intA).textFieldStyle(.odField).keyboardType(.numbersAndPunctuation).frame(maxWidth: 90)
                Text("to")
                TextField("b", text: $intB).textFieldStyle(.odField).keyboardType(.numbersAndPunctuation).frame(maxWidth: 90)
                if let s = cache.definite {
                    Text(String(format: "= %.8g", s)).foregroundStyle(ODTheme.good)
                        .lineLimit(1).minimumScaleFactor(0.7)
                } else {
                    Text("= —")
                }
            }
            HStack {
                Button { importing = true } label: { Label("Import CSV points", systemImage: "square.and.arrow.down") }
                if !importedPoints.isEmpty { Button("Clear points") { importedPoints = []; importStatus = "" } }
                Spacer()
            }
            .buttonStyle(.bordered)
            if !importStatus.isEmpty { Text(importStatus) }
        }
        .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
            switch result {
            case .success(let url): importCSV(url)
            case .failure(let error): importStatus = error.localizedDescription
            }
        }
    }

    /// Central-difference dy/dx, step scaled to x (degrees mode applies inside the evaluator).
    private func derivative(_ expr: String, at x: Double) -> Double? {
        let h = max(1e-6, abs(x) * 1e-6)
        guard let yp = yAt(expr, x + h), let ym = yAt(expr, x - h) else { return nil }
        let d = (yp - ym) / (2 * h)
        return d.isFinite ? d : nil
    }

    /// Composite Simpson's rule (1,000 intervals) over [a, b]; nil if y₁ is undefined anywhere.
    private func simpson(_ expr: String, _ a: Double, _ b: Double) -> Double? {
        guard a.isFinite, b.isFinite, a != b else { return a == b ? 0 : nil }
        let n = 1000, h = (b - a) / Double(n)
        var sum = 0.0
        for i in 0...n {
            guard let y = yAt(expr, a + Double(i) * h) else { return nil }
            sum += y * (i == 0 || i == n ? 1 : (i % 2 == 1 ? 4 : 2))
        }
        return sum * h / 3
    }

    /// Bisection-refined root of g in [x0, x1] (g changes sign across it).
    private func refineRoot(_ g: (Double) -> Double?, _ x0: Double, _ x1: Double) -> Double? {
        var a = x0, b = x1
        guard var ga = g(a), let gb = g(b), (ga <= 0) != (gb <= 0) else { return nil }
        for _ in 0..<60 {
            let m = 0.5 * (a + b)
            guard let gm = g(m) else { return nil }
            if (gm <= 0) == (ga <= 0) { a = m; ga = gm } else { b = m }
        }
        let root = 0.5 * (a + b)
        // Reject sign changes across a pole (tan, 1/x): the value must actually be small.
        guard let gr = g(root), abs(gr) < 1e-6 * max(1, abs(ga), abs(gb)) else { return nil }
        return root
    }

    /// x where y₁ − y₂ changes sign across the view, each refined by bisection.
    private func intersections() -> [Double] {
        let g: (Double) -> Double? = { x in
            guard let a = yAt(f1, x), let b = yAt(f2, x) else { return nil }
            return a - b
        }
        var out: [Double] = []
        let n = 600, step = (hi - lo) / Double(n)
        var prev = g(lo)
        for i in 1...n {
            let x = lo + Double(i) * step
            let cur = g(x)
            if let p = prev, let c = cur, (p <= 0) != (c <= 0), let r = refineRoot(g, x - step, x) {
                out.append(r)
                if out.count >= 24 { break }
            }
            prev = cur
        }
        return out
    }

    /// Two numeric columns (x, y) per line; comma, semicolon or tab separated.
    /// A header row or any non-numeric row is skipped.
    private func importCSV(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { importStatus = "Couldn't read that file as text."; return }
        var points: [(x: Double, y: Double)] = []
        var skipped = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let cells = line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" }).map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count >= 2, let x = Double(cells[0]), let y = Double(cells[1]), x.isFinite, y.isFinite {
                points.append((x, y))
            } else { skipped += 1 }
        }
        guard !points.isEmpty else { importStatus = "No x,y number pairs found."; return }
        importedPoints = Array(points.prefix(5000))
        importStatus = "Imported \(importedPoints.count) point(s)\(skipped > 0 ? ", skipped \(skipped) line(s)" : "")."
        if let minX = importedPoints.map(\.x).min(), let maxX = importedPoints.map(\.x).max(), maxX > minX {
            let pad = (maxX - minX) * 0.05
            xmin = String(format: "%.6g", minX - pad); xmax = String(format: "%.6g", maxX + pad)
        }
    }

    private func zoom(_ factor: Double) {
        let c = (lo + hi) / 2, half = (hi - lo) / 2 * factor
        xmin = String(format: "%.4g", c - half); xmax = String(format: "%.4g", c + half)
    }
    private func pan(_ frac: Double) {
        let d = (hi - lo) * frac
        xmin = String(format: "%.4g", lo + d); xmax = String(format: "%.4g", hi + d)
    }
    /// Zero crossings of the sampled trace, refined by linear interpolation.
    private func zeros(of pts: [GraphPoint]) -> [Double] {
        var out: [Double] = []; var prev: GraphPoint?
        for p in pts {
            if let pr = prev, let y0 = pr.y, let y1 = p.y, y0.isFinite, y1.isFinite, (y0 <= 0) != (y1 <= 0), y0 != y1,
               let root = refineRoot({ yAt(f1, $0) }, pr.x, p.x) {
                out.append(root)
                if out.count >= 24 { break }
            }
            prev = p
        }
        return out
    }
    /// Trapezoidal definite integral of the sampled trace across the window.
    private func integral(of pts: [GraphPoint]) -> Double {
        var s = 0.0; var prev: GraphPoint?
        for p in pts {
            if let pr = prev, let y0 = pr.y, let y1 = p.y, y0.isFinite, y1.isFinite { s += 0.5 * (y0 + y1) * (p.x - pr.x) }
            prev = p
        }
        return s
    }
}
private struct OptionalYDomain:ViewModifier{let enabled:Bool,lo:Double,hi:Double;@ViewBuilder func body(content:Content)->some View{if enabled{content.chartYScale(domain:min(lo,hi-0.001)...max(hi,lo+0.001))}else{content}}}

// MARK: - Tiny BASIC

private let tinyBasicSample = """
10 REM Tiny BASIC
20 CLS
30 FOR I = 0 TO 11
40 LINE 120,67,120+100*COS(I*30),67+60*SIN(I*30),3
50 NEXT
60 CIRCLE 120,67,30,5
70 TEXT 78,4,"ORBITDECK BASIC"
80 SHOW
90 PRINT "Drew a 12-spoke rosette."
100 END
"""

struct TinyBasicView:View{
    @State private var source=tinyBasicSample
    @State private var output=""
    @State private var ops:[BasicGraphicOp]=[]
    @State private var status=""
    var body:some View{GeometryReader{geo in if geo.size.width>780{HStack(spacing:12){editor;display}.padding()}else{ScrollView{VStack{editor;display}.padding()}}}}
    private var editor:some View{VStack(alignment:.leading){HStack{Button("Run"){run()}.buttonStyle(.borderedProminent);Button("Clear"){output="";ops=[];status=""};Button("Sample"){source=tinyBasicSample};ShareLink(item:source,preview:SharePreview("OrbitDeck BASIC program")){Label("Share source",systemImage:"square.and.arrow.up")}};TextEditor(text:$source).font(.system(.body,design:.monospaced)).frame(minHeight:300).overlay(RoundedRectangle(cornerRadius:8).stroke(ODTheme.grid));Text("Output").font(.headline);ScrollView{Text(output.isEmpty ? "(no output)":output).font(.system(.body,design:.monospaced)).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}.frame(minHeight:100).odPanel();Text(status).font(.caption).foregroundStyle(ODTheme.muted)}.frame(maxWidth:.infinity)}
    private var display:some View{VStack(alignment:.leading){Text("Display · 240 × 135").font(.headline);Canvas{ctx,size in let scale=min(size.width/240,size.height/135);let ox=(size.width-240*scale)/2,oy=(size.height-135*scale)/2;ctx.fill(rectPath(CGRect(x:ox,y:oy,width:240*scale,height:135*scale)),with:.color(.black));for op in ops{func p(_ x:Double,_ y:Double)->CGPoint{CGPoint(x:ox+x*scale,y:oy+y*scale)};let col=Color(hex:TinyBasicEngine.palette[max(0,min(TinyBasicEngine.palette.count-1,op.color))]);switch op.kind{case .cls:ctx.fill(rectPath(CGRect(x:ox,y:oy,width:240*scale,height:135*scale)),with:.color(.black));case .pset:if op.values.count>=2{let q=p(op.values[0],op.values[1]);ctx.fill(rectPath(CGRect(x:q.x,y:q.y,width:max(1,scale),height:max(1,scale))),with:.color(col))};case .line:if op.values.count>=4{var path=Path();path.move(to:p(op.values[0],op.values[1]));path.addLine(to:p(op.values[2],op.values[3]));ctx.stroke(path,with:.color(col),lineWidth:max(1,scale))};case .circle:if op.values.count>=3{let q=p(op.values[0],op.values[1]),rr=op.values[2]*scale;ctx.stroke(Path(ellipseIn:CGRect(x:q.x-rr,y:q.y-rr,width:2*rr,height:2*rr)),with:.color(col),lineWidth:max(1,scale))};case .text:if op.values.count>=2{ctx.draw(Text(op.text).font(.system(size:max(7,5*scale),design:.monospaced)).foregroundStyle(.white),at:p(op.values[0],op.values[1]),anchor:.topLeading)};case .show:break}}}.aspectRatio(240/135,contentMode:.fit).frame(minHeight:280).odPanel();Text("0.6 foundation supports numbered programs, variables A–Z, assignments, PRINT, FOR/NEXT, IF…THEN line jumps, GOTO/GOSUB/RETURN, and CLS/PSET/LINE/CIRCLE/TEXT/SHOW. Arrays, DATA/READ, live satellite host variables, INPUT and sandboxed file statements are planned.").font(.caption).foregroundStyle(ODTheme.muted)}.frame(maxWidth:.infinity)}
    private func run(){do{let r=try TinyBasicEngine().run(source);output=r.output.joined(separator:"\n");ops=r.graphics;status="Ran \(r.steps) statement(s); \(r.graphics.count) graphics call(s)."}catch{output="?\(error.localizedDescription)";status=error.localizedDescription}}
}

// MARK: - References

struct ReferencesView:View{
    @State private var selected = OrbitReferences.tables[0].id
    @State private var query = ""
    private var table:ReferenceTable{OrbitReferences.tables.first{$0.id==selected} ?? OrbitReferences.tables[0]}
    private var rows:[ReferenceRow]{guard !query.isEmpty else{return table.rows};let q=query.lowercased();return table.rows.filter{($0.a+" "+$0.b+" "+$0.c).lowercased().contains(q)}}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    ForEach(OrbitReferences.tables) { t in
                        Button(t.name) { selected = t.id; query = "" }
                    }
                } label: {
                    HStack {
                        Text(table.name).font(.headline)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").foregroundStyle(ODTheme.muted)
                    }
                    .padding()
                    .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                .tint(.primary)

                Text(table.description).foregroundStyle(ODTheme.muted)
                TextField("Filter rows", text: $query).textFieldStyle(.odField)

                HStack {
                    Text(table.headers[safe: 0] ?? "").frame(width: 100, alignment: .leading)
                    Text(table.headers[safe: 1] ?? "").frame(width: 180, alignment: .leading)
                    Text(table.headers[safe: 2] ?? "").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.bold()).foregroundStyle(ODTheme.muted)

                ForEach(rows) { r in
                    HStack(alignment: .top) {
                        Text(r.a).font(.body.monospaced()).frame(width: 100, alignment: .leading)
                        Text(r.b).frame(width: 180, alignment: .leading)
                        Text(r.c).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
            }
            .padding()
        }
    }
}
private extension Array{ subscript(safe index:Int)->Element?{indices.contains(index) ? self[index]:nil} }

// MARK: - Learn

private enum LearnTopic:String,CaseIterable,Identifiable{case speed="Orbital speed",horizon="Horizon & footprint",slant="Slant range",drift="Track drift",doppler="Doppler",link="Link budget";var id:String{rawValue}}
struct LearnView:View{
    @State private var topic: LearnTopic = .speed
    @State private var altitude = 500.0
    @State private var elevation = 20.0
    @State private var frequency = 145.8
    @State private var rangeRate = -5.0
    @State private var eirp = 27.0
    @State private var rxGain = 6.0
    @State private var sensitivity = -120.0
    var body:some View{ScrollView{VStack(alignment:.leading,spacing:14){Picker("Lesson",selection:$topic){ForEach(LearnTopic.allCases){Text($0.rawValue).tag($0)}}.pickerStyle(.segmented);lesson.odPanel();Text("These interactive lessons reuse the same physical constants and basic geometry as the operating tools. More lessons — Kepler equal-area demonstrations, transfers, element-age/decay, coverage accumulation, eclipse timelines, transponder/duplex practice, antenna patterns, constellation lessons and printable handouts — are planned.").font(.caption).foregroundStyle(ODTheme.muted)}.padding()}}
    @ViewBuilder private var lesson:some View{VStack(alignment:.leading,spacing:12){switch topic{case .speed:Text("Why low satellites move faster").font(.title2.bold());slider("Circular altitude",$altitude,100...40000,"km");let speed=LearnMath.circularSpeed(altitudeKm:altitude),period=LearnMath.circularPeriodMinutes(altitudeKm:altitude);metric("Orbital speed",ODFormat.units(String(format:"%.3f km/s",speed)));metric("Period",String(format:"%.1f min",period));Chart(Array(stride(from: 100, through: 40000, by: 500).enumerated()).map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.circularSpeed(altitudeKm: Double($0.element))) }) { p in if let y = p.y { LineMark(x: .value("Altitude", p.x), y: .value("Speed", y)) } }.frame(height:260)
        case .horizon:Text("How altitude expands the footprint").font(.title2.bold());slider("Altitude",$altitude,100...40000,"km");metric("Horizon radius",ODFormat.units(String(format:"%.0f km",LearnMath.horizonRadiusKm(altitudeKm:altitude))));metric("Angular radius",String(format:"%.1f°",LearnMath.horizonRadiusKm(altitudeKm:altitude)/LearnMath.earthRadiusKm*180/Double.pi));Chart(Array(stride(from: 100, through: 40000, by: 500).enumerated()).map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.horizonRadiusKm(altitudeKm: Double($0.element))) }) { p in if let y = p.y { LineMark(x: .value("Altitude", p.x), y: .value("Footprint", y)) } }.frame(height:260)
        case .slant:Text("Why range changes strongly near the horizon").font(.title2.bold());slider("Altitude",$altitude,100...2000,"km");slider("Elevation",$elevation,0...90,"°");metric("Slant range",ODFormat.units(String(format:"%.0f km",LearnMath.slantRangeKm(altitudeKm:altitude,elevationDeg:elevation))));Chart((0...90).enumerated().map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.slantRangeKm(altitudeKm: altitude, elevationDeg: Double($0.element))) }) { p in if let y = p.y { LineMark(x: .value("Elevation", p.x), y: .value("Range", y)) } }.frame(height:260)
        case .drift:Text("Earth turns beneath each orbit").font(.title2.bold());slider("Altitude",$altitude,100...40000,"km");let p=LearnMath.circularPeriodMinutes(altitudeKm:altitude),drift=LearnMath.trackDriftDegrees(altitudeKm:altitude);metric("Orbital period",String(format:"%.1f min",p));metric("Westward ground-track shift",String(format:"%.1f° per orbit",drift));Text("The spacecraft returns to its orbital plane after one period, but Earth has rotated east underneath it. On a ground map the next trace therefore appears displaced westward by roughly this amount.").foregroundStyle(ODTheme.muted)
        case .doppler:Text("Range rate becomes frequency shift").font(.title2.bold());slider("Frequency",$frequency,29...2400,"MHz");slider("Range rate",$rangeRate,-8...8,"km/s");metric("One-way Doppler",String(format:"%+.0f Hz",LearnMath.dopplerHz(freqMHz:frequency,rangeRateKmS:rangeRate)));Chart((-80...80).enumerated().map { GraphPoint(id: $0.offset, x: Double($0.element) / 10.0, y: LearnMath.dopplerHz(freqMHz: frequency, rangeRateKmS: Double($0.element) / 10.0)) }) { p in if let y = p.y { LineMark(x: .value("Range rate", p.x), y: .value("Shift", y)) } }.frame(height:260)
        case .link:Text("Free-space link budget sandbox").font(.title2.bold());slider("Frequency",$frequency,29...2400,"MHz");slider("Range",$altitude,100...5000,"km");slider("TX EIRP",$eirp,-10...50,"dBm");slider("RX gain",$rxGain,-5...25,"dBi");slider("Sensitivity",$sensitivity,-145 ... -80,"dBm");let loss=LearnMath.fsplDb(rangeKm:altitude,freqMHz:frequency),rx=eirp-loss+rxGain,margin=rx-sensitivity;metric("Path loss",String(format:"%.1f dB",loss));metric("RX power",String(format:"%.1f dBm",rx));metric("Margin",String(format:"%+.1f dB",margin))}}
        .padding()}
    @ViewBuilder private func slider(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>,_ unit:String)->some View{VStack(alignment:.leading){Text(ODFormat.units("\(label): \(String(format: "%.1f", value.wrappedValue)) \(unit)")).font(.caption.monospacedDigit());Slider(value:value,in:range)}}
    private func metric(_ l:String,_ v:String)->some View{HStack{Text(l).foregroundStyle(ODTheme.muted);Spacer();Text(v).font(.body.monospacedDigit())}}
}

func rectPath(_ rect: CGRect) -> Path { Path { $0.addRect(rect) } }

extension Color{init(hex:String){let s=hex.trimmingCharacters(in:CharacterSet.alphanumerics.inverted);var n:UInt64=0;Scanner(string:s).scanHexInt64(&n);let r=Double((n>>16)&255)/255,g=Double((n>>8)&255)/255,b=Double(n&255)/255;self.init(red:r,green:g,blue:b)}}


// MARK: - Location converter / grid distance tools

/// One formatted coordinate with a copy button, shared by the geo tools.
private struct CopyableRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(ODTheme.muted).frame(width: 110, alignment: .leading)
            Text(value).font(.body.monospaced()).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 6)
            Button {
                UIPasteboard.general.string = value
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy \(label)")
        }
    }
}

/// Every supported representation of one position.
private func geoFormatRows(_ ll: LatLon) -> [(String, String)] {
    let lat = ll.latitude, lon = ll.longitude
    var rows: [(String, String)] = [
        ("Grid (4)", GeoFormats.maidenhead(latitude: lat, longitude: lon, length: 4)),
        ("Grid (6)", GeoFormats.maidenhead(latitude: lat, longitude: lon, length: 6)),
        ("Grid (8)", GeoFormats.maidenhead(latitude: lat, longitude: lon, length: 8)),
        ("Decimal", GeoFormats.decimal(latitude: lat, longitude: lon)),
        ("DMS", GeoFormats.dms(latitude: lat, longitude: lon)),
        ("DDM", GeoFormats.ddm(latitude: lat, longitude: lon)),
        ("Plus Code", GeoFormats.plusCode(latitude: lat, longitude: lon))
    ]
    if let utm = GeoFormats.utm(latitude: lat, longitude: lon) { rows.append(("UTM", utm.text)) }
    if let mgrs = GeoFormats.mgrs(latitude: lat, longitude: lon) { rows.append(("MGRS", mgrs)) }
    if let usng = GeoFormats.mgrs(latitude: lat, longitude: lon, spaced: true) { rows.append(("USNG", usng)) }
    return rows
}

/// Location converter tool: type any supported format (or take a GPS fix) and
/// read it back in all of them.
struct LocationConverterView: View {
    @EnvironmentObject private var store: OrbitStore
    @StateObject private var location = LocationProvider()
    @AppStorage("geoTools.converterInput") private var input = ""
    @State private var waitingForFix = false

    private var station: LatLon {
        LatLon(latitude: store.preferences.observer.latitude, longitude: store.preferences.observer.longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("FN20xa · 39.93, -74.89 · 18S UJ 23487 06483 · 87G7VM8C+2R", text: $input)
                .textFieldStyle(.odField)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack(spacing: 10) {
                Button {
                    waitingForFix = true
                    location.setPrecise(true)
                    location.requestLocation()
                } label: { Label("Use my location", systemImage: "location.fill") }
                    .buttonStyle(.bordered)
                Button {
                    input = GeoFormats.decimal(latitude: station.latitude, longitude: station.longitude)
                } label: { Label("Station", systemImage: "house") }
                    .buttonStyle(.bordered)
                if waitingForFix { ProgressView().controlSize(.small) }
            }
            if let err = location.errorMessage {
                Text(err).font(.caption).foregroundStyle(ODTheme.warning)
            }
            Divider()
            if let parsed = GeoFormats.parseAny(input, reference: station) {
                Text("Read as \(parsed.format)").font(.caption).foregroundStyle(ODTheme.muted)
                ForEach(geoFormatRows(parsed.location), id: \.0) { row in
                    CopyableRow(label: row.0, value: row.1)
                }
                Text("WGS84. UTM and MGRS/USNG cover 80°S–84°N (no polar UPS). A UTM entry needs its latitude band letter (18S, not 18N/S hemisphere). Short Plus Codes are resolved near your station.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } else if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Unrecognized. Enter a Maidenhead grid, degrees (decimal, DMS or DDM), a Plus Code, UTM (zone + band, easting, northing) or MGRS/USNG.")
                    .font(.caption).foregroundStyle(ODTheme.warning)
            }
        }
        .onChange(of: location.location) { _, fix in
            guard waitingForFix, let fix, fix.horizontalAccuracy >= 0 else { return }
            waitingForFix = false
            input = GeoFormats.decimal(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        }
    }
}

/// Grid distance & bearing tool: short/long path from the station (or a GPS
/// fix) to a grid, coordinates or callsign.
struct GridDistanceView: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rot: RotatorController
    @StateObject private var location = LocationProvider()
    @AppStorage("geoTools.distanceTarget") private var target = ""
    @State private var gpsOrigin: LatLon?
    @State private var waitingForFix = false
    @State private var callResult: (call: String, label: String, location: LatLon)?
    @State private var lookupMessage = ""
    @State private var looking = false
    private static let qrz = QRZService()

    private var origin: LatLon {
        gpsOrigin ?? LatLon(latitude: store.preferences.observer.latitude, longitude: store.preferences.observer.longitude)
    }

    private var trimmedTarget: String { target.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A callsign-looking entry (letters and digits, at least one of each, optional /suffix).
    private var looksLikeCall: Bool {
        let t = trimmedTarget.uppercased()
        guard (3...14).contains(t.count), t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" }) else { return false }
        return t.contains(where: \.isNumber) && t.contains(where: \.isLetter)
    }

    private var resolved: (label: String, location: LatLon)? {
        if let parsed = GeoFormats.parseAny(trimmedTarget, reference: origin) { return (parsed.format, parsed.location) }
        if let r = callResult, r.call == trimmedTarget.uppercased() { return (r.label, r.location) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("From").foregroundStyle(ODTheme.muted)
                Text(gpsOrigin == nil ? store.preferences.observer.name : "GPS fix").lineLimit(1)
                Text(GeoFormats.maidenhead(latitude: origin.latitude, longitude: origin.longitude, length: 6))
                    .font(.body.monospaced()).fixedSize()
                Spacer()
                if waitingForFix { ProgressView().controlSize(.small) }
                if gpsOrigin == nil {
                    Button { waitingForFix = true; location.requestLocation() } label: { Image(systemName: "location.fill") }
                        .buttonStyle(.bordered).accessibilityLabel("Use my location")
                } else {
                    Button { gpsOrigin = nil } label: { Image(systemName: "house") }
                        .buttonStyle(.bordered).accessibilityLabel("Use station location")
                }
            }
            HStack {
                TextField("Grid, lat/lon or callsign", text: $target)
                    .textFieldStyle(.odField)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onSubmit { if resolved == nil && looksLikeCall { lookUpCall() } }
                if looksLikeCall && GeoFormats.parseAny(trimmedTarget, reference: origin) == nil {
                    Button("Look up") { lookUpCall() }.buttonStyle(.bordered).disabled(looking)
                }
            }
            if !lookupMessage.isEmpty { Text(lookupMessage).font(.caption).foregroundStyle(ODTheme.muted) }
            if let err = location.errorMessage { Text(err).font(.caption).foregroundStyle(ODTheme.warning) }
            Divider()
            if let r = resolved {
                let path = GreatCirclePath.path(from: origin, to: r.location)
                MetricRow("Target", "\(GeoFormats.maidenhead(latitude: r.location.latitude, longitude: r.location.longitude, length: 6)) · \(r.label)")
                MetricRow("Target position", String(format: "%.4f°, %.4f°", r.location.latitude, r.location.longitude))
                MetricRow("Short path", ODFormat.km(path.shortKm, decimals: 0), valueColor: ODTheme.good)
                MetricRow("Short-path bearing", String(format: "%.1f° %@", path.bearing, ODFormat.compass(path.bearing)), valueColor: ODTheme.good)
                MetricRow("Long path", ODFormat.km(path.longKm, decimals: 0))
                MetricRow("Long-path bearing", String(format: "%.1f° %@", path.longBearing, ODFormat.compass(path.longBearing)))
                MetricRow("Their heading to you", String(format: "%.1f° %@", path.reverseBearing, ODFormat.compass(path.reverseBearing)))
                HStack {
                    Button { point(bearing: path.bearing) } label: { Label("Point rotator (SP)", systemImage: "scope") }
                        .buttonStyle(.borderedProminent)
                    Button { point(bearing: path.longBearing) } label: { Label("LP", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.bordered)
                }
                .disabled(!rot.connected)
                Text("Great circle on a spherical Earth (mean radius 6,371 km); bearings are true north. The rotator buttons send the azimuth at 0° elevation.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            } else if !trimmedTarget.isEmpty && !looksLikeCall {
                Text("Unrecognized target.").font(.caption).foregroundStyle(ODTheme.warning)
            }
        }
        .onChange(of: location.location) { _, fix in
            guard waitingForFix, let fix, fix.horizontalAccuracy >= 0 else { return }
            waitingForFix = false
            gpsOrigin = LatLon(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        }
    }

    private func point(bearing: Double) {
        rot.pointManually(azimuth: bearing, elevation: 0)
    }

    /// QRZ grid when credentials are configured; otherwise (or on failure) the
    /// callsign's DXCC entity reference point.
    private func lookUpCall() {
        let call = trimmedTarget.uppercased()
        let username = store.preferences.qrzUsername ?? ""
        let password = OrbitSecretStore.get(.qrzPassword)
        func dxccFallback(_ note: String) {
            if let match = DXCCLookup.entity(for: call), let ref = DXCCNumericData.byCode[match.code] {
                callResult = (call, "DXCC \(match.name)", LatLon(latitude: ref.latitude, longitude: ref.longitude))
                lookupMessage = note + "Using the \(match.name) DXCC reference point."
            } else {
                callResult = nil
                lookupMessage = note + "No DXCC entity found for \(call)."
            }
        }
        guard !username.isEmpty, !password.isEmpty else { dxccFallback(""); return }
        looking = true
        lookupMessage = "Looking up \(call) on QRZ…"
        Task { @MainActor in
            defer { looking = false }
            do {
                let record = try await Self.qrz.lookup(username: username, password: password, callsign: DXCCLookup.baseCall(call))
                if let ll = GeoFormats.gridCenter(record.grid) {
                    callResult = (call, "QRZ grid \(record.grid)", ll)
                    lookupMessage = record.name.isEmpty ? "" : record.name
                } else {
                    dxccFallback("QRZ has no grid for \(call). ")
                }
            } catch {
                dxccFallback("\(error.localizedDescription) ")
            }
        }
    }
}


// MARK: - Comet position tool

/// Comet position (Tools → Satellite & orbit). CardSat parity (0.9.76): built-in
/// presets or typed elements, two-body from perihelion.
struct CometPositionView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var presetIndex = 0          // −1 = custom elements
    @State private var custom = CometElements(name: "Custom comet", perihelionAU: 1.0, eccentricity: 0.9, inclinationDeg: 10,
                                              nodeDeg: 0, argPerihelionDeg: 0, perihelionTime: .now)
    private var elements: CometElements {
        presetIndex >= 0 && presetIndex < FeatureEngine.cometPresets.count ? FeatureEngine.cometPresets[presetIndex] : custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Comet", selection: $presetIndex) {
                ForEach(Array(FeatureEngine.cometPresets.enumerated()), id: \.offset) { index, comet in
                    Text(comet.name).tag(index)
                }
                Text("Custom elements…").tag(-1)
            }
            .pickerStyle(.menu)
            if presetIndex < 0 {
                VStack(alignment: .leading, spacing: 6) {
                    elementField("Perihelion q (AU)", $custom.perihelionAU)
                    elementField("Eccentricity e", $custom.eccentricity)
                    elementField("Inclination i (°)", $custom.inclinationDeg)
                    elementField("Node Ω (°)", $custom.nodeDeg)
                    elementField("Arg. perihelion ω (°)", $custom.argPerihelionDeg)
                    DatePicker("Perihelion Tp", selection: $custom.perihelionTime, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    Text("J2000 ecliptic elements, as published by JPL's Small-Body Database or the Minor Planet Center. Tp is in UTC.")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                }
                .padding().odPanel()
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let c = elements
                let p = FeatureEngine.cometPosition(c, site: store.preferences.observer, at: context.date)
                VStack(alignment: .leading, spacing: 12) {
                    SectionCard(c.name) {
                        MetricRow("Right ascension", raText(p.raDeg))
                        MetricRow("Declination", String(format: "%+.2f°", p.decDeg))
                        MetricRow("Azimuth", "\(ODFormat.angle(p.azimuthDeg))  \(ODFormat.compass(p.azimuthDeg))")
                        MetricRow("Elevation", ODFormat.angle(p.elevationDeg), valueColor: p.elevationDeg > 0 ? ODTheme.good : ODTheme.muted)
                        MetricRow("From the Sun (r)", String(format: "%.3f AU", p.heliocentricAU))
                        MetricRow("From Earth (Δ)", String(format: "%.3f AU", p.geocentricAU))
                        MetricRow("Elongation", String(format: "%.1f°", p.elongationDeg),
                                  valueColor: p.elongationDeg < 20 ? ODTheme.warning : .primary)
                        MetricRow("Perihelion", ODFormat.utcDayString(c.perihelionTime))
                        MetricRow(p.daysFromPerihelion >= 0 ? "Since perihelion" : "Until perihelion",
                                  String(format: "%.1f days", abs(p.daysFromPerihelion)))
                        if p.alwaysUp {
                            MetricRow("Rise / set", "Up all day")
                        } else if p.neverUp {
                            MetricRow("Rise / set", "Below the horizon all day")
                        } else {
                            MetricRow("Next rise", p.rise.map { ODFormat.utcShort.string(from: $0) } ?? "—")
                            MetricRow("Next set", p.set.map { ODFormat.utcShort.string(from: $0) } ?? "—")
                        }
                    }
                    if abs(p.daysFromPerihelion) > 730 {
                        Label(String(format: "These elements describe the %@ perihelion, %.0f years ago. Planetary perturbations (mostly Jupiter) accumulate, so the position can be off by degrees — enter current elements from JPL or the MPC for anything precise.",
                                     ODFormat.utcDayString(c.perihelionTime), abs(p.daysFromPerihelion) / 365.25),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(ODTheme.warning)
                    }
                    if p.elongationDeg < 20 {
                        Text("Within 20° of the Sun — lost in twilight even when above the horizon.")
                            .font(.caption).foregroundStyle(ODTheme.warning)
                    }
                }
            }
            Text("Two-body propagation of osculating elements (universal-variable Kepler solve for elliptic, parabolic and hyperbolic orbits), one light-time iteration, J2000 RA/Dec, no parallax. Built-in elements: JPL Small-Body Database, rounded, as shipped in CardSat. Rise/set use −0.57° refraction. Brightness isn't predicted — comet magnitudes are notoriously unpredictable.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
    }

    private func elementField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 170, alignment: .leading)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...6)))
                .textFieldStyle(.odField)
                .keyboardType(.numbersAndPunctuation)
        }
    }

    private func raText(_ deg: Double) -> String {
        let hours = deg / 15
        let h = Int(hours), m = (hours - Double(h)) * 60
        return String(format: "%02dh %04.1fm  (%.2f°)", h, m, deg)
    }
}

extension ODFormat {
    /// Date-only stamp in the operator's display zone.
    static func utcDayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = displayTimeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - Debris-group screen

/// Debris groups fetched this session (never merged into the main catalog). Kept
/// in memory so re-screening honors CelesTrak's two-hour-per-dataset request.
@MainActor private enum DebrisGroupCache {
    static var groups: [String: (date: Date, records: [SatelliteRecord])] = [:]
}

/// Screens a transient CelesTrak fragmentation cloud against the selected
/// satellite (CardSat parity, 0.9.59). The resident catalog is untouched.
struct DebrisScreenView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var groupID = GPService.celestrakGroups.first { $0.name.hasPrefix("Debris:") }?.id ?? "cosmos-2251-debris"
    @State private var hours = 6.0
    @State private var thresholdKm = 25.0
    @State private var result: DebrisScreenResult?
    @State private var running = false
    @State private var status = ""
    @State private var job: Task<Void, Never>?
    @State private var shareURL: URL?

    private var groups: [CelesTrakGroup] { GPService.celestrakGroups.filter { $0.name.hasPrefix("Debris:") } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let sat = store.selectedSatellite {
                Text("Screening \(sat.name) (\(ODFormat.units(String(format: "%.0f × %.0f km", sat.perigeeKm, sat.apogeeKm))))")
                    .font(.subheadline.bold())
            } else {
                Text("Select a satellite first.").foregroundStyle(ODTheme.warning)
            }
            Picker("Debris group", selection: $groupID) {
                ForEach(groups) { Text($0.name.replacingOccurrences(of: "Debris: ", with: "")).tag($0.id) }
            }
            .pickerStyle(.menu)
            Picker("Window", selection: $hours) {
                Text("6 h").tag(6.0); Text("12 h").tag(12.0); Text("24 h").tag(24.0)
            }
            .pickerStyle(.segmented)
            Picker("Report within", selection: $thresholdKm) {
                Text(ODFormat.units("10 km")).tag(10.0); Text(ODFormat.units("25 km")).tag(25.0)
                Text(ODFormat.units("50 km")).tag(50.0); Text(ODFormat.units("100 km")).tag(100.0)
            }
            .pickerStyle(.segmented)
            HStack {
                Button(running ? "Screening…" : "Fetch & screen") { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(running || store.selectedSatellite == nil)
                if running {
                    ProgressView()
                    Button("Cancel") { job?.cancel() }
                }
                Spacer()
                if let shareURL { ShareLink(item: shareURL) { Label("CSV", systemImage: "square.and.arrow.up") } }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(ODTheme.muted) }
            if let result {
                SectionCard("Closest approaches (\(result.hits.count))") {
                    if result.hits.isEmpty {
                        Text("No object in this group comes within \(ODFormat.units(String(format: "%.0f km", thresholdKm))) in the next \(Int(hours)) h.")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    ForEach(result.hits) { hit in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(hit.name).font(.subheadline)
                                Text(verbatim: "NORAD \(hit.id) · \(ODFormat.utcShort.string(from: hit.date))")
                                    .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text(ODFormat.units(String(format: "%.1f km", hit.missDistanceKm)))
                                    .font(.body.monospaced()).foregroundStyle(ODTheme.warning)
                                Text(ODFormat.units(String(format: "Δv %.2f km/s", hit.relativeVelocityKmS)))
                                    .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                            }
                        }
                    }
                }
            }
            Text("The group is downloaded from CelesTrak for this session only — your satellite catalog isn't changed. Objects whose perigee–apogee band can't reach the satellite are skipped; the rest are sampled every 30 s and refined to 1 s. Public GP elements are km-class accurate: this is awareness, not collision avoidance.")
                .font(.caption).foregroundStyle(ODTheme.warning)
        }
        .onDisappear { job?.cancel() }
    }

    private func start() {
        guard let primary = store.selectedSatellite else { return }
        let id = groupID, h = hours, threshold = thresholdKm
        running = true; result = nil; shareURL = nil
        job = Task {
            defer { running = false }
            let records: [SatelliteRecord]
            if let cached = DebrisGroupCache.groups[id] {
                records = cached.records
            } else if !store.celestrakAllowed("debris-\(id)") {
                status = "CelesTrak asks clients to fetch each dataset at most once every two hours; try again in \(store.celestrakCooldownMinutes("debris-\(id)")) min."
                return
            } else {
                status = "Downloading the debris group…"
                do {
                    guard let url = URL(string: GPService.celestrakBase + id) else { return }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 45
                    request.setValue(AppInfo.userAgent, forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    store.recordCelestrakFetch("debris-\(id)")
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw GPServiceError.badResponse(http.statusCode)
                    }
                    records = try GPService.parse(data: data)
                    DebrisGroupCache.groups[id] = (Date(), records)
                } catch {
                    status = error.localizedDescription
                    return
                }
            }
            status = "Screening \(records.count) objects…"
            let start = Date()
            do {
                // The detached task doesn't inherit cancellation, so forward it: leaving the
                // screen (job?.cancel()) stops the screening loop instead of letting it run on.
                let worker = Task.detached(priority: .userInitiated) {
                    try FeatureEngine.screenDebrisGroup(primary: primary, debris: records, from: start, hours: h, thresholdKm: threshold)
                }
                let screened = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if Task.isCancelled { status = "Canceled."; return }
                result = screened
                status = "\(screened.groupCount) objects in the group, \(screened.bandCount) in an overlapping altitude band, screened from \(ODFormat.utcShort.string(from: start))."
                var csv = "norad,name,tca_utc,miss_km,relative_velocity_km_s\n"
                for hit in screened.hits {
                    csv += "\(hit.id),\"\(hit.name)\",\(ISO8601DateFormatter().string(from: hit.date)),\(String(format: "%.3f", hit.missDistanceKm)),\(String(format: "%.4f", hit.relativeVelocityKmS))\n"
                }
                shareURL = try? OrbitExportService.temporaryTextFile(name: "OrbitDeck-debris-\(id).csv", text: csv)
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

// MARK: - Notes

/// Multi-note plain-text editor (CardSat parity: Log → Notes). Files live in
/// Documents/Notes, so they're also visible and editable in the Files app.
struct NotesView: View {
    @State private var notes: [NoteFile] = []
    @State private var query = ""
    @State private var openNote: URL?
    @State private var renaming: NoteFile?
    @State private var renameText = ""
    @State private var deleting: NoteFile?
    @State private var errorText: String?

    private var filtered: [NoteFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return notes }
        return notes.filter { ($0.title + "\n" + $0.text).lowercased().contains(q) }
    }

    var body: some View {
        List {
            if notes.isEmpty {
                Text("No notes yet. Tap + to start one — for skeds, frequencies, grids to work or a pass plan. Notes are plain-text files you can also open in the Files app (On My iPhone → OrbitDeck → Notes).")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            ForEach(filtered) { note in
                Button { openNote = note.url } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.title).font(.headline).foregroundStyle(.primary)
                        Text(note.modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(ODTheme.muted)
                        if !note.text.isEmpty {
                            Text(note.text.prefix(160)).font(.caption).foregroundStyle(ODTheme.muted).lineLimit(2)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { deleting = note } label: { Label("Delete", systemImage: "trash") }
                    Button { renameText = note.title; renaming = note } label: { Label("Rename", systemImage: "pencil") }
                }
                .contextMenu {
                    Button { renameText = note.title; renaming = note } label: { Label("Rename", systemImage: "pencil") }
                    ShareLink(item: note.url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { deleting = note } label: { Label("Delete", systemImage: "trash") }
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(ODTheme.warning) }
        }
        .searchable(text: $query, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newNote() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New note")
            }
        }
        .navigationDestination(item: $openNote) { url in NoteEditorView(url: url) }
        .onAppear { reload() }
        .onChange(of: openNote) { _, url in if url == nil { reload() } }
        .alert("Rename note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let note = renaming {
                    do { _ = try NotesStore.rename(note.url, to: renameText) } catch { errorText = error.localizedDescription }
                }
                renaming = nil; reload()
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let note = deleting {
                    do { try NotesStore.delete(note.url) } catch { errorText = error.localizedDescription }
                }
                deleting = nil; reload()
            }
        } message: {
            Text(deleting?.title ?? "")
        }
    }

    private func reload() { notes = NotesStore.list() }

    private func newNote() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HHmm'z'"
        do { openNote = try NotesStore.create(title: "Note \(f.string(from: Date()))") } catch { errorText = error.localizedDescription }
    }
}

/// Editor for one note; saves shortly after each edit and when leaving.
struct NoteEditorView: View {
    let url: URL
    @State private var text = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var status = ""
    /// Text as last read from or written to disk; saves are skipped when unchanged.
    @State private var savedText = ""
    /// Set when the file couldn't be read: editing and saving are disabled so the
    /// original file is never overwritten with an empty buffer.
    @State private var readError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let readError {
                Text("This note couldn't be read, so editing is disabled to protect the file: \(readError)")
                    .font(.caption).foregroundStyle(ODTheme.warning).padding(8)
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .disabled(readError != nil)
            if !status.isEmpty {
                Text(status).font(.caption2).foregroundStyle(ODTheme.muted).padding(.bottom, 4)
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
        }
        .onAppear {
            guard !loaded else { return }
            do {
                text = try NotesStore.read(url)
                savedText = text
                loaded = true
            } catch {
                readError = error.localizedDescription
            }
        }
        .onChange(of: text) { _, _ in
            guard loaded, readError == nil else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !Task.isCancelled { save() }
            }
        }
        .onDisappear { saveTask?.cancel(); if loaded { save() } }
    }

    private func save() {
        guard loaded, readError == nil, text != savedText else { return }
        do { try NotesStore.write(text, to: url); savedText = text; status = "Saved \(Date().formatted(date: .omitted, time: .shortened))" }
        catch { status = error.localizedDescription }
    }
}

// MARK: - Help

/// Multi-paragraph body text with real paragraph spacing. Each line of `text` is a
/// paragraph (blank lines are ignored); "1. …", "• …" and "- …" lines get a hanging
/// indent so wrapped lines align under the text, not under the number.
struct ParagraphText: View {
    let text: String
    var spacing: CGFloat = 10

    private struct Line: Identifiable { let id: Int; let marker: String?; let body: String }

    private var lines: [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { i, line in
                if let r = line.range(of: #"^(\d+\.|•|-)\s+"#, options: .regularExpression) {
                    return Line(id: i, marker: String(line[r]).trimmingCharacters(in: .whitespaces),
                                body: String(line[r.upperBound...]))
                }
                return Line(id: i, marker: nil, body: line)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(lines) { line in
                if let marker = line.marker {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker == "-" ? "•" : marker).monospacedDigit()
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(line.body)
                    }
                } else {
                    Text(line.body)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Searchable in-app help (HelpLibrary articles) with a link to the readiness checklist.
struct HelpView: View {
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    NavigationLink { StationReadinessView() } label: {
                        Label("Station readiness checklist", systemImage: "checklist")
                    }
                }
            }
            let hits = HelpLibrary.search(query)
            let areas = hits.map(\.area).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(areas, id: \.self) { area in
                Section(area) {
                    ForEach(hits.filter { $0.area == area }) { article in
                        NavigationLink {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(article.title).font(.title3.bold())
                                    ParagraphText(text: article.body).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                            }
                            .navigationTitle(article.area)
                        } label: {
                            Text(article.title)
                        }
                    }
                }
            }
            if !query.isEmpty && hits.isEmpty {
                Text("No help articles match “\(query)”.").foregroundStyle(ODTheme.muted)
            }
            Section {
                Link(destination: URL(string: "https://orbitdeckios.n8hm.radio/documentation.html")!) {
                    Label("Full documentation (website)", systemImage: "safari")
                }
            }
        }
        .searchable(text: $query, prompt: "Search help")
    }
}

// MARK: - Station readiness

enum ReadinessState: Sendable {
    case ok, warn, missing, optional

    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .missing: "xmark.circle.fill"
        case .optional: "circle.dashed"
        }
    }
    var color: Color {
        switch self {
        case .ok: ODTheme.good
        case .warn: ODTheme.warning
        case .missing: .red
        case .optional: ODTheme.muted
        }
    }
    var label: String {
        switch self {
        case .ok: "OK"
        case .warn: "CHECK"
        case .missing: "MISSING"
        case .optional: "OPTIONAL"
        }
    }
}

/// Where a readiness row's "fix" goes.
enum ReadinessFix: Sendable {
    case settings, satellites, refreshGP, logSettings, rig, rotator, requestNotifications, systemSettings
}

struct ReadinessItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let state: ReadinessState
    let fix: ReadinessFix?
}

/// The checklist itself (CardSat parity: About → r). Shared by the readiness
/// screen and the readiness PDF so both report the same thing.
enum StationReadiness {
    @MainActor
    static func evaluate(store: OrbitStore, qso: QSOStore, rig: RigController, rotator: RotatorController,
                         audio: AudioHub) async -> [ReadinessItem] {
        var items: [ReadinessItem] = []
        let prefs = store.preferences
        let site = prefs.observer

        // Location
        let auth = CLLocationManager().authorizationStatus
        if store.locationMode == .currentLocation {
            switch auth {
            case .authorizedAlways, .authorizedWhenInUse:
                items.append(.init(id: "loc", title: "Location", detail: String(format: "Following this device · %@ (%.3f°, %.3f°)", store.operatorGrid6, site.latitude, site.longitude), state: .ok, fix: nil))
            case .denied, .restricted:
                items.append(.init(id: "loc", title: "Location", detail: "Always use current location is on, but Location access is denied. Allow it in the Settings app, or switch to a fixed site.", state: .missing, fix: .systemSettings))
            default:
                items.append(.init(id: "loc", title: "Location", detail: "Waiting for Location permission and a first fix.", state: .warn, fix: .settings))
            }
        } else {
            let isDefault = site.latitude == ObserverSite().latitude && site.longitude == ObserverSite().longitude
            items.append(.init(id: "loc", title: "Location", detail: isDefault
                               ? "Your station is still the built-in default. Set it in Settings → Observer station (coordinates, grid, or current location)."
                               : "Fixed site \(site.name) · \(store.operatorGrid6)", state: isDefault ? .missing : .ok, fix: isDefault ? .settings : nil))
        }

        // Elements and favorites
        if let age = store.catalogAgeDays {
            let state: ReadinessState = age <= 2 ? .ok : (age <= 7 ? .warn : .missing)
            items.append(.init(id: "gp", title: "GP element data", detail: String(format: "%d objects · newest set %.1f days old", store.satellites.count, age), state: state, fix: state == .ok ? nil : .refreshGP))
        } else {
            items.append(.init(id: "gp", title: "GP element data", detail: "No catalog loaded yet. Update elements now (needs a connection).", state: .missing, fix: .refreshGP))
        }
        items.append(.init(id: "fav", title: "Favorites", detail: prefs.favorites.isEmpty ? "No favorite satellites — star a few in Satellites; Home and the schedules follow them." : "\(prefs.favorites.count) favorite satellite(s)",
                           state: prefs.favorites.isEmpty ? .warn : .ok, fix: prefs.favorites.isEmpty ? .satellites : nil))

        // Identity and services
        let call = (prefs.callsign ?? "").trimmingCharacters(in: .whitespaces)
        items.append(.init(id: "call", title: "Callsign", detail: call.isEmpty ? "Not set (Settings → Operator identity)." : call.uppercased(), state: call.isEmpty ? .missing : .ok, fix: call.isEmpty ? .settings : nil))
        let qrz = !(prefs.qrzUsername ?? "").isEmpty && !OrbitSecretStore.get(.qrzPassword).isEmpty
        items.append(.init(id: "qrz", title: "QRZ lookup", detail: qrz ? "Username and password saved" : "Not configured — needed for callsign lookups and name fill.", state: qrz ? .ok : .optional, fix: qrz ? nil : .settings))
        let lotw = (qso.config.hasLoTWCredential || LoTW.hasCredential()) && !qso.config.station.call.isEmpty
        items.append(.init(id: "lotw", title: "LoTW upload", detail: lotw ? "Certificate imported · station \(qso.config.station.call)" : "No callsign certificate or station location yet (Log → Log settings).", state: lotw ? .ok : .optional, fix: lotw ? nil : .logSettings))
        let cloudlog = !qso.config.cloudlog.url.isEmpty && !OrbitSecretStore.get(.cloudlogKey).isEmpty
        items.append(.init(id: "cloudlog", title: "Cloudlog / Wavelog", detail: cloudlog ? qso.config.cloudlog.url : "Not configured (Log → Log settings).", state: cloudlog ? .ok : .optional, fix: cloudlog ? nil : .logSettings))

        // Notifications
        let notify = await UNUserNotificationCenter.current().notificationSettings()
        switch notify.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            items.append(.init(id: "notify", title: "Notifications", detail: "Allowed — pass alarms and activation reminders can alert you.", state: .ok, fix: nil))
        case .denied:
            items.append(.init(id: "notify", title: "Notifications", detail: "Denied — pass alarms can't alert you. Allow them in the Settings app.", state: .warn, fix: .systemSettings))
        default:
            items.append(.init(id: "notify", title: "Notifications", detail: "Not asked yet — needed only for pass alarms and reminders.", state: .optional, fix: .requestNotifications))
        }

        // Hardware
        if rig.config.isConfigured {
            items.append(.init(id: "cat", title: "Rig control (CAT)", detail: rig.connected ? "Configured and connected" : "Configured, not connected — connect from Home before the pass.", state: rig.connected ? .ok : .warn, fix: rig.connected ? nil : .rig))
        } else {
            items.append(.init(id: "cat", title: "Rig control (CAT)", detail: "Not configured (optional Doppler tuning of your radio).", state: .optional, fix: .rig))
        }
        if rotator.config.isConfigured {
            items.append(.init(id: "rot", title: "Rotator", detail: rotator.connected ? "Configured and connected" : "Configured, not connected — connect from Home before the pass.", state: rotator.connected ? .ok : .warn, fix: rotator.connected ? nil : .rotator))
        } else {
            items.append(.init(id: "rot", title: "Rotator", detail: "Not configured (optional az/el antenna steering).", state: .optional, fix: .rotator))
        }
        items.append(.init(id: "audio", title: "Audio interface", detail: audio.audioAvailable
                           ? (audio.usbConnected ? "USB audio interface connected" : "Icom network audio ready")
                           : "None connected, so the recording, SSTV, FT4, packet and remote-voice cards are hidden on Home. To use them with the built-in mic, set them to Always in Settings → Audio features.",
                           state: audio.audioAvailable ? .ok : .optional, fix: audio.audioAvailable ? nil : .settings))
        return items
    }

    /// The checklist as a PDF report.
    static func reportPDF(_ items: [ReadinessItem], station: String) -> Data {
        let ready = items.filter { $0.state == .missing }.isEmpty
        return StationReportService.textPDF(
            title: "Station readiness",
            subtitle: "\(station) · \(ODFormat.utc.string(from: Date())) · \(ready ? "No blocking items" : "Items need attention")",
            sections: items.map { ReportSection(heading: "[\($0.state.label)]  \($0.title)", lines: [$0.detail]) },
            footer: "OrbitDeck iOS · readiness report")
    }
}

/// Checklist screen: shown once on first run and from Settings / Help.
struct StationReadinessView: View {
    var firstRun = false
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var qso: QSOStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var rotator: RotatorController
    @EnvironmentObject private var audio: AudioHub
    @EnvironmentObject private var router: NotificationRouter
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ReadinessItem] = []
    @State private var showLogSettings = false
    @State private var showRig = false
    @State private var showRotator = false
    @State private var shareURL: URL?

    var body: some View {
        List {
            if firstRun {
                Section {
                    Text("Welcome to OrbitDeck. Here's what's set up and what isn't — tap an item to fix it. You can come back to this any time from Settings → Station readiness or Help.")
                        .font(.callout)
                }
            }
            Section {
                ForEach(items) { item in
                    Button { perform(item.fix) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.state.symbol).foregroundStyle(item.state.color).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).foregroundStyle(.primary)
                                Text(item.detail).font(.caption).foregroundStyle(ODTheme.muted)
                            }
                            Spacer()
                            if item.fix != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(ODTheme.muted) }
                        }
                    }
                    .disabled(item.fix == nil)
                }
            } footer: {
                Text("Green is ready, amber needs a look, red blocks useful results; gray items are optional.")
            }
            Section {
                Button { Task { await refresh() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                Button {
                    shareURL = try? OrbitExportService.temporaryFile(name: "OrbitDeck-readiness.pdf",
                                                                     data: StationReadiness.reportPDF(items, station: store.preferences.observer.name))
                } label: { Label("Readiness report (PDF)", systemImage: "doc.richtext") }
            }
        }
        .navigationTitle("Station readiness")
        .task { await refresh() }
        .onChange(of: store.isRefreshingGP) { _, busy in if !busy { Task { await refresh() } } }
        .sheet(isPresented: $showLogSettings, onDismiss: { Task { await refresh() } }) { NavigationStack { LogSettingsView() } }
        .sheet(isPresented: $showRig, onDismiss: { Task { await refresh() } }) {
            NavigationStack {
                RigControlSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showRig = false } } }
            }
        }
        .sheet(isPresented: $showRotator, onDismiss: { Task { await refresh() } }) {
            NavigationStack {
                RotatorSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showRotator = false } } }
            }
        }
        .sheet(item: Binding(get: { shareURL.map { ShareURLItem(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { item in
            ActivityView(url: item.url)
        }
    }

    private func refresh() async {
        items = await StationReadiness.evaluate(store: store, qso: qso, rig: rig, rotator: rotator, audio: audio)
    }

    private func perform(_ fix: ReadinessFix?) {
        switch fix {
        case .settings?: router.openDestination = .settings; dismiss()
        case .satellites?: router.openDestination = .satellites; dismiss()
        case .refreshGP?: Task { await store.refreshGP(); await refresh() }
        case .logSettings?: showLogSettings = true
        case .rig?: showRig = true
        case .rotator?: showRotator = true
        case .requestNotifications?:
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                await refresh()
            }
        case .systemSettings?:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case nil: break
        }
    }
}

// MARK: - Station & outreach reports

/// Exports card: favorites' keps (TLE + PDF), readiness report, Support AMSAT
/// sheet and an operator contact card. All go out through the share sheet
/// (which also offers AirPrint).
struct StationReportsCard: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var qso: QSOStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var rotator: RotatorController
    @EnvironmentObject private var audio: AudioHub
    @AppStorage("orbitdeck.contactCard.name") private var operatorName = ""
    @State private var shareURL: URL?
    @State private var status = ""

    private var favorites: [SatelliteRecord] {
        store.satellites.filter { store.preferences.favorites.contains($0.id) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        SectionCard("Station & outreach reports") {
            Text("Favorite satellites' element sets, a station-readiness report, a one-page Support AMSAT sheet and a contact card with a QR code to your QRZ page. Use the share sheet to print.")
                .font(.caption).foregroundStyle(ODTheme.muted)
            ViewThatFits {
                HStack {
                    Button("Keps TLE") { prepareTLE() }
                    Button("Keps PDF") { share("OrbitDeck-keps.pdf", StationReportService.kepsPDF(favorites)) }
                    Button("Readiness PDF") { Task { await prepareReadiness() } }
                }
                VStack(alignment: .leading) {
                    Button("Favorites' keps (TLE text)") { prepareTLE() }
                    Button("Favorites' keps (PDF)") { share("OrbitDeck-keps.pdf", StationReportService.kepsPDF(favorites)) }
                    Button("Station readiness (PDF)") { Task { await prepareReadiness() } }
                }
            }
            .disabled(store.satellites.isEmpty)
            Button("Support AMSAT sheet (PDF)") { share("Support-AMSAT.pdf", StationReportService.supportAMSATPDF()) }
            HStack {
                TextField("Your name (for the contact card)", text: $operatorName).textFieldStyle(.odField)
                Button("Contact card") {
                    share("OrbitDeck-contact-card.pdf",
                          StationReportService.contactCardPDF(callsign: store.preferences.callsign ?? "", name: operatorName, grid: store.operatorGrid6))
                }
            }
            if (store.preferences.callsign ?? "").isEmpty {
                Text("Set your callsign in Settings → Operator identity to put it on the contact card.").font(.caption2).foregroundStyle(ODTheme.warning)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(ODTheme.muted) }
        }
        .sheet(item: Binding(get: { shareURL.map { ShareURLItem(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { item in
            ActivityView(url: item.url)
        }
    }

    private func prepareTLE() {
        guard !favorites.isEmpty else { status = "No favorite satellites to export."; return }
        do { shareURL = try OrbitExportService.temporaryTextFile(name: "OrbitDeck-favorites.tle", text: TLEFormatter.text(for: favorites)) }
        catch { status = error.localizedDescription }
    }

    private func prepareReadiness() async {
        let items = await StationReadiness.evaluate(store: store, qso: qso, rig: rig, rotator: rotator, audio: audio)
        share("OrbitDeck-readiness.pdf", StationReadiness.reportPDF(items, station: store.preferences.observer.name))
    }

    private func share(_ name: String, _ data: Data) {
        if name.hasPrefix("OrbitDeck-keps"), favorites.isEmpty { status = "No favorite satellites to export."; return }
        do { shareURL = try OrbitExportService.temporaryFile(name: name, data: data) } catch { status = error.localizedDescription }
    }
}

// MARK: - Factory reset

/// Clears settings, caches and stored data. The QSO log (with recordings and SSTV
/// images) and notes can be kept; Keychain passwords are removed only on request.
enum FactoryResetService {
    struct Options {
        var keepLogAndMedia = true
        var keepNotes = true
        var removeSecrets = false
    }

    /// Set once a reset has run: stores check it and stop persisting, so nothing still in
    /// memory writes the erased data back before the app is relaunched.
    @MainActor private(set) static var didReset = false

    @MainActor static func run(_ options: Options) {
        didReset = true
        // Pass alarms and activation reminders (pending and already delivered).
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        let fm = FileManager.default
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        UserDefaults.standard.synchronize()

        func contents(_ url: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
        }
        // Application Support: QSOLog/recordings/SSTV files live at its root (QSOStore),
        // caches under OrbitDeck/, the LoTW certificate as lotw.p12.
        var keep: Set<String> = []
        if options.keepLogAndMedia {
            keep.formUnion(["QSOLog.json", "Recordings.json", "Recordings", "SSTVImages.json", "SSTV", "FT4Traffic.json"])
        }
        if !options.removeSecrets { keep.insert("lotw.p12") }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for item in contents(support) where !keep.contains(item.lastPathComponent) {
            if item.lastPathComponent == "OrbitDeck", options.keepNotes {
                // Tiny BASIC programs are user documents, kept with the notes.
                for sub in contents(item) where sub.lastPathComponent != "Basic" { try? fm.removeItem(at: sub) }
            } else {
                try? fm.removeItem(at: item)
            }
        }
        for dir in [fm.urls(for: .cachesDirectory, in: .userDomainMask)[0], fm.temporaryDirectory] {
            for item in contents(dir) { try? fm.removeItem(at: item) }
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for item in contents(docs) where !(options.keepNotes && item.lastPathComponent == "Notes") {
            try? fm.removeItem(at: item)
        }
        if options.removeSecrets { OrbitSecretStore.clearAll() }
    }
}

/// Settings → Reset.
struct FactoryResetSection: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var rig: RigController
    @EnvironmentObject private var rotator: RotatorController
    @EnvironmentObject private var qsoLog: QSOStore
    @EnvironmentObject private var liveActivity: LiveActivityController
    @State private var options = FactoryResetService.Options()
    @State private var confirmStep = 0
    @State private var done = false

    var body: some View {
        Section {
            Toggle("Keep QSO log, recordings & SSTV images", isOn: $options.keepLogAndMedia)
            Toggle("Keep notes & BASIC programs", isOn: $options.keepNotes)
            Toggle("Also remove saved passwords, keys & LoTW certificate", isOn: $options.removeSecrets)
            Button(role: .destructive) { confirmStep = 1 } label: {
                Label("Reset OrbitDeck…", systemImage: "arrow.counterclockwise.circle")
            }
            Text("Erases every setting (station, sites, favorites, calibrations, CAT, rotator, auto switching, digital modes, logging setup), the downloaded catalogs and caches, and — unless kept above — the QSO log, recordings and notes. Saved passwords and API keys stay in the iOS Keychain unless you choose to remove them. Back up first if you might want anything back.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        } header: {
            Text("Reset")
        }
        .confirmationDialog("Reset OrbitDeck?", isPresented: Binding(get: { confirmStep == 1 }, set: { if !$0 && confirmStep == 1 { confirmStep = 0 } }),
                            titleVisibility: .visible) {
            Button("Continue", role: .destructive) { confirmStep = 2 }
            Button("Cancel", role: .cancel) { confirmStep = 0 }
        } message: {
            Text(summary)
        }
        .alert("This can't be undone", isPresented: Binding(get: { confirmStep == 2 }, set: { if !$0 && confirmStep == 2 { confirmStep = 0 } })) {
            Button("Erase now", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) { confirmStep = 0 }
        } message: {
            Text("All OrbitDeck settings and data listed will be erased from this device.")
        }
        .fullScreenCover(isPresented: $done) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle").font(.system(size: 54)).foregroundStyle(ODTheme.good)
                Text("Reset complete").font(.title2.bold())
                Text("Close OrbitDeck from the app switcher (swipe it away), then open it again to start fresh.")
                    .multilineTextAlignment(.center).foregroundStyle(ODTheme.muted)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ODTheme.background.ignoresSafeArea())
            .interactiveDismissDisabled()
        }
    }

    private var summary: String {
        var parts = ["All settings and caches will be erased."]
        parts.append(options.keepLogAndMedia ? "Your QSO log, recordings and SSTV images are kept." : "Your QSO log, recordings and SSTV images will be DELETED.")
        parts.append(options.keepNotes ? "Notes and BASIC programs are kept." : "Notes and BASIC programs will be DELETED.")
        parts.append(options.removeSecrets ? "Saved passwords, API keys and the LoTW certificate will be removed from the Keychain." : "Saved passwords and API keys in the Keychain are left alone.")
        return parts.joined(separator: " ")
    }

    private func reset() {
        confirmStep = 0
        rig.disconnect()
        rotator.disconnect()
        // Stop background writers first: the QRZ fill would otherwise save a deleted log
        // back, and the Live Activity loop would restart the activity.
        qsoLog.prepareForFactoryReset(keepLog: options.keepLogAndMedia)
        liveActivity.stopForFactoryReset()
        FactoryResetService.run(options)
        // Put the live store back to defaults (in memory only — saving is blocked by
        // `didReset`) so nothing shows or writes the old settings before the relaunch.
        store.preferences = StorePreferences()
        done = true
    }
}
