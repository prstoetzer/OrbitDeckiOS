import SwiftUI
import Charts

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
            Canvas { context, size in
                let r=min(size.width,size.height)/2-24, c=CGPoint(x:size.width/2,y:size.height/2)
                context.fill(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:2*r,height:2*r)), with:.color(ODTheme.globeOcean))
                context.stroke(Path(ellipseIn:CGRect(x:c.x-r,y:c.y-r,width:2*r,height:2*r)), with:.color(ODTheme.grid), lineWidth:1.5)
                drawNight(context:&context,size:size,c:c,r:r,center:center,date:date)
                drawGraticule(context:&context,c:c,r:r,center:center)
                drawCoastlines(context:&context,c:c,r:r,center:center)
                if let p=project(lat:store.preferences.observer.latitude,lon:store.preferences.observer.longitude,center:center,c:c,r:r) { context.draw(Text("★").foregroundStyle(ODTheme.warning).font(.title3),at:p) }
                drawTrack(context:&context,satellite:sat,date:date,center:center,c:c,r:r)
                drawFootprint(context:&context,lat:look.subLatitude,lon:look.subLongitude,alt:look.altitudeKm,center:center,c:c,r:r,color:ODTheme.good)
                for fs in favorites where fs.id != sat.id {
                    if let fl = try? OrbitPredictor.look(fs, observer: store.preferences.observer, at: date) {
                        drawSatelliteGlyph(context: &context, satellite: fs, date: date, look: fl,
                                           center: center, c: c, r: r, color: ODTheme.accent, size: 12)
                    }
                }
                drawSatelliteGlyph(context: &context, satellite: sat, date: date, look: look,
                                   center: center, c: c, r: r, color: ODTheme.good, size: 15)
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
                    globeStat("Altitude", String(format: "%.0f km", look.altitudeKm))
                    globeStat("Azimuth", String(format: "%.0f°", look.azimuth))
                    globeStat("Elevation", String(format: "%+.1f°", look.elevation))
                    globeStat("Range", String(format: "%.0f km", look.rangeKm))
                    globeStat("Range rate", String(format: "%+.2f km/s", look.rangeRateKmS))
                    globeStat("Footprint", String(format: "%.0f km", look.footprintRadiusKm * 2))
                    globeStat("Beta angle", String(format: "%+.1f°", look.betaAngleDeg))
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
    /// satellite's direction of travel (sampled ~1 min ahead).
    private func drawSatelliteGlyph(context: inout GraphicsContext, satellite: SatelliteRecord, date: Date, look: LiveLook,
                                    center: (Double, Double), c: CGPoint, r: Double,
                                    color: Color, size: CGFloat) {
        guard let surface = project(lat: look.subLatitude, lon: look.subLongitude, center: center, c: c, r: r) else { return }
        let scale = 1 + altitudeFraction(look.altitudeKm)
        let glyph = CGPoint(x: c.x + (surface.x - c.x) * scale, y: c.y + (surface.y - c.y) * scale)
        var tether = Path(); tether.move(to: surface); tether.addLine(to: glyph)
        context.stroke(tether, with: .color(color.opacity(0.4)), lineWidth: 0.7)
        context.fill(Path(ellipseIn: CGRect(x: surface.x - 1.5, y: surface.y - 1.5, width: 3, height: 3)),
                     with: .color(color.opacity(0.5)))

        var angle: Double?
        if let ahead = try? OrbitPredictor.look(satellite, observer: store.preferences.observer, at: date.addingTimeInterval(60)),
           let aheadSurface = project(lat: ahead.subLatitude, lon: ahead.subLongitude, center: center, c: c, r: r) {
            let aheadScale = 1 + altitudeFraction(ahead.altitudeKm)
            let ag = CGPoint(x: c.x + (aheadSurface.x - c.x) * aheadScale, y: c.y + (aheadSurface.y - c.y) * aheadScale)
            if hypot(ag.x - glyph.x, ag.y - glyph.y) > 0.5 { angle = atan2(ag.y - glyph.y, ag.x - glyph.x) }
        }
        if let angle {
            drawHeadingArrow(&context, at: glyph, angle: angle, color: color, size: size * 0.5)
        } else {
            let d = size * 0.32
            context.fill(Path(ellipseIn: CGRect(x: glyph.x - d, y: glyph.y - d, width: 2 * d, height: 2 * d)), with: .color(color))
        }
        context.draw(Text(satellite.name).font(.system(size: 8, weight: .semibold)).foregroundStyle(color.opacity(0.9)),
                     at: CGPoint(x: glyph.x, y: glyph.y - size * 0.9))
    }

    private func centerPoint(look:LiveLook)->(Double,Double) { switch mode { case .satellite:return(look.subLatitude,look.subLongitude);case .station:return(store.preferences.observer.latitude,store.preferences.observer.longitude);case .north:return(90,0);case .south:return(-90,0);case .free:return(freeLat,freeLon) } }
    private func project(lat:Double,lon:Double,center:(Double,Double),c:CGPoint,r:Double)->CGPoint? { let la=lat*Double.pi/180,lo=lon*Double.pi/180,cl=center.0*Double.pi/180,co=center.1*Double.pi/180; let cosc=sin(cl)*sin(la)+cos(cl)*cos(la)*cos(lo-co); guard cosc>=0 else{return nil}; let x=cos(la)*sin(lo-co),y=cos(cl)*sin(la)-sin(cl)*cos(la)*cos(lo-co); return CGPoint(x:c.x+r*x,y:c.y-r*y) }
    private func drawGraticule(context:inout GraphicsContext,c:CGPoint,r:Double,center:(Double,Double)) { for lat in stride(from:-60.0,through:60.0,by:30){ drawGeoLine(context:&context,points:stride(from:-180.0,through:180.0,by:4).map{(lat,$0)},center:center,c:c,r:r,color:ODTheme.grid.opacity(0.7),width:0.6) }; for lon in stride(from:-180.0,through:180.0,by:30){drawGeoLine(context:&context,points:stride(from:-90.0,through:90.0,by:4).map{($0,lon)},center:center,c:c,r:r,color:ODTheme.grid.opacity(0.7),width:0.6)} }
    private func drawCoastlines(context:inout GraphicsContext,c:CGPoint,r:Double,center:(Double,Double)) { for polyline in WorldMapData.coastlines { drawGeoLine(context:&context,points:polyline.map { ($0.1,$0.0) },center:center,c:c,r:r,color:.white.opacity(0.55),width:1.0) } }
    private func drawGeoLine(context:inout GraphicsContext,points:[(Double,Double)],center:(Double,Double),c:CGPoint,r:Double,color:Color,width:Double){ var p=Path(),started=false; for ll in points { if let q=project(lat:ll.0,lon:ll.1,center:center,c:c,r:r){ if started{p.addLine(to:q)}else{p.move(to:q);started=true} } else { if started{context.stroke(p,with:.color(color),lineWidth:width);p=Path();started=false} } }; if started{context.stroke(p,with:.color(color),lineWidth:width)} }
    private func drawTrack(context:inout GraphicsContext,satellite:SatelliteRecord,date:Date,center:(Double,Double),c:CGPoint,r:Double){ let period=max(60,satellite.periodMinutes*60); let points=(0...120).compactMap{i->(Double,Double)? in let t=date.addingTimeInterval(-period/2+period*Double(i)/120); guard let l=try? OrbitPredictor.look(satellite,observer:store.preferences.observer,at:t)else{return nil};return(l.subLatitude,l.subLongitude)}; drawGeoLine(context:&context,points:points,center:center,c:c,r:r,color:ODTheme.accent,width:1.8) }
    private func drawFootprint(context:inout GraphicsContext,lat:Double,lon:Double,alt:Double,center:(Double,Double),c:CGPoint,r:Double,color:Color){ let re=6378.135,ang=acos(re/(re+max(1,alt)))*180/Double.pi; let pts=stride(from:0.0,through:360.0,by:5).map{destination(lat:lat,lon:lon,distanceDeg:ang,bearingDeg:$0)}; drawGeoLine(context:&context,points:pts,center:center,c:c,r:r,color:color.opacity(0.8),width:1.1) }
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
    private let engine=GraphCalculatorEngine()
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
                            Spacer()
                            Button("Clear trace") { traceX = nil }.font(.caption2)
                        }
                        .font(.caption.monospaced())
                    }
                    analysis
                }
                Text("Degrees mode. Drag on the plot to trace. Evaluator supports x, pi/e and the same functions as the scientific calculator (trig/inverse/hyperbolic, ln/log/log2/exp, sqrt/cbrt, RF/orbit helpers, metric prefixes). Undefined points break the trace.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }
            .padding()
        }
    }

    @ViewBuilder private var graph: some View {
        let a = engine.sample(f1, xmin: lo, xmax: hi)
        let b = f2.trimmingCharacters(in: .whitespaces).isEmpty ? [] : engine.sample(f2, xmin: lo, xmax: hi)
        let roots = zeros(of: a)
        Chart {
            ForEach(a) { p in if let y = p.y { LineMark(x: .value("x", p.x), y: .value("y", y)).foregroundStyle(ODTheme.good) } }
            ForEach(b) { p in if let y = p.y { LineMark(x: .value("x", p.x), y: .value("y2", y)).foregroundStyle(ODTheme.accent) } }
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
        let a = engine.sample(f1, xmin: lo, xmax: hi)
        let roots = zeros(of: a)
        let area = integral(of: a)
        HStack {
            Text(roots.isEmpty ? "No zeros of y₁ in view" : "Zeros of y₁: " + roots.prefix(6).map { String(format: "%.3g", $0) }.joined(separator: ", ") + (roots.count > 6 ? "…" : ""))
            Spacer()
            Text(String(format: "∫y₁ dx ≈ %.4g", area))
        }
        .font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
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
            if let pr = prev, let y0 = pr.y, let y1 = p.y, y0.isFinite, y1.isFinite, (y0 <= 0) != (y1 <= 0), y0 != y1 {
                out.append(pr.x + (y0 / (y0 - y1)) * (p.x - pr.x))
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
    @ViewBuilder private var lesson:some View{VStack(alignment:.leading,spacing:12){switch topic{case .speed:Text("Why low satellites move faster").font(.title2.bold());slider("Circular altitude",$altitude,100...40000,"km");let speed=LearnMath.circularSpeed(altitudeKm:altitude),period=LearnMath.circularPeriodMinutes(altitudeKm:altitude);metric("Orbital speed",String(format:"%.3f km/s",speed));metric("Period",String(format:"%.1f min",period));Chart(Array(stride(from: 100, through: 40000, by: 500).enumerated()).map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.circularSpeed(altitudeKm: Double($0.element))) }) { p in if let y = p.y { LineMark(x: .value("Altitude", p.x), y: .value("Speed", y)) } }.frame(height:260)
        case .horizon:Text("How altitude expands the footprint").font(.title2.bold());slider("Altitude",$altitude,100...40000,"km");metric("Horizon radius",String(format:"%.0f km",LearnMath.horizonRadiusKm(altitudeKm:altitude)));metric("Angular radius",String(format:"%.1f°",LearnMath.horizonRadiusKm(altitudeKm:altitude)/LearnMath.earthRadiusKm*180/Double.pi));Chart(Array(stride(from: 100, through: 40000, by: 500).enumerated()).map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.horizonRadiusKm(altitudeKm: Double($0.element))) }) { p in if let y = p.y { LineMark(x: .value("Altitude", p.x), y: .value("Footprint", y)) } }.frame(height:260)
        case .slant:Text("Why range changes strongly near the horizon").font(.title2.bold());slider("Altitude",$altitude,100...2000,"km");slider("Elevation",$elevation,0...90,"°");metric("Slant range",String(format:"%.0f km",LearnMath.slantRangeKm(altitudeKm:altitude,elevationDeg:elevation)));Chart((0...90).enumerated().map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.slantRangeKm(altitudeKm: altitude, elevationDeg: Double($0.element))) }) { p in if let y = p.y { LineMark(x: .value("Elevation", p.x), y: .value("Range", y)) } }.frame(height:260)
        case .drift:Text("Earth turns beneath each orbit").font(.title2.bold());slider("Altitude",$altitude,100...40000,"km");let p=LearnMath.circularPeriodMinutes(altitudeKm:altitude),drift=LearnMath.trackDriftDegrees(altitudeKm:altitude);metric("Orbital period",String(format:"%.1f min",p));metric("Westward ground-track shift",String(format:"%.1f° per orbit",drift));Text("The spacecraft returns to its orbital plane after one period, but Earth has rotated east underneath it. On a ground map the next trace therefore appears displaced westward by roughly this amount.").foregroundStyle(ODTheme.muted)
        case .doppler:Text("Range rate becomes frequency shift").font(.title2.bold());slider("Frequency",$frequency,29...2400,"MHz");slider("Range rate",$rangeRate,-8...8,"km/s");metric("One-way Doppler",String(format:"%+.0f Hz",LearnMath.dopplerHz(freqMHz:frequency,rangeRateKmS:rangeRate)));Chart((-80...80).enumerated().map { GraphPoint(id: $0.offset, x: Double($0.element) / 10.0, y: LearnMath.dopplerHz(freqMHz: frequency, rangeRateKmS: Double($0.element) / 10.0)) }) { p in if let y = p.y { LineMark(x: .value("Range rate", p.x), y: .value("Shift", y)) } }.frame(height:260)
        case .link:Text("Free-space link budget sandbox").font(.title2.bold());slider("Frequency",$frequency,29...2400,"MHz");slider("Range",$altitude,100...5000,"km");slider("TX EIRP",$eirp,-10...50,"dBm");slider("RX gain",$rxGain,-5...25,"dBi");slider("Sensitivity",$sensitivity,-145 ... -80,"dBm");let loss=LearnMath.fsplDb(rangeKm:altitude,freqMHz:frequency),rx=eirp-loss+rxGain,margin=rx-sensitivity;metric("Path loss",String(format:"%.1f dB",loss));metric("RX power",String(format:"%.1f dBm",rx));metric("Margin",String(format:"%+.1f dB",margin))}}
        .padding()}
    @ViewBuilder private func slider(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>,_ unit:String)->some View{VStack(alignment:.leading){Text("\(label): \(value.wrappedValue,specifier:"%.1f") \(unit)").font(.caption.monospacedDigit());Slider(value:value,in:range)}}
    private func metric(_ l:String,_ v:String)->some View{HStack{Text(l).foregroundStyle(ODTheme.muted);Spacer();Text(v).font(.body.monospacedDigit())}}
}

func rectPath(_ rect: CGRect) -> Path { Path { $0.addRect(rect) } }

extension Color{init(hex:String){let s=hex.trimmingCharacters(in:CharacterSet.alphanumerics.inverted);var n:UInt64=0;Scanner(string:s).scanHexInt64(&n);let r=Double((n>>16)&255)/255,g=Double((n>>8)&255)/255,b=Double(n&255)/255;self.init(red:r,green:g,blue:b)}}

