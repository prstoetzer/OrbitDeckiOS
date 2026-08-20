import SwiftUI
import Charts
import UniformTypeIdentifiers

// MARK: - Expanded Tools

struct DeepToolsView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var selected = BenchTools.allTools.first!.id
    @State private var values: [String: String] = [:]
    @State private var exportMessage = ""

    private var spec: ToolDefinition {
        BenchTools.allTools.first { $0.id == selected } ?? BenchTools.allTools[0]
    }

    private var numeric: [String: Double] {
        Dictionary(uniqueKeysWithValues: spec.fields.map { ($0.id, Double(values[$0.id] ?? "") ?? $0.defaultValue) })
    }

    private var results: [ToolResult] {
        BenchTools.deepParity2Results(for: selected, raw: values, values: numeric)
            ?? BenchTools.deepParityResults(for: selected, values: numeric)
            ?? BenchTools.results(for: selected, values: numeric)
    }

    private func choices(for field: ToolField) -> [String] {
        if spec.id == "unitConverter", field.id == "from" || field.id == "to" {
            let family = Int(Double(values["family"] ?? "") ?? spec.fields.first(where: { $0.id == "family" })?.defaultValue ?? 0)
            return BenchTools.unitChoices(familyIndex: family)
        }
        return field.choices ?? []
    }

    private var categories: [String] {
        Array(Set(BenchTools.allTools.map { $0.category })).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Menu {
                    ForEach(categories, id: \.self) { category in
                        Section(category) {
                            ForEach(BenchTools.allTools.filter { $0.category == category }) { tool in
                                Button(tool.name) { selected = tool.id; values = [:] }
                            }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.category).font(.caption).foregroundStyle(ODTheme.muted)
                            Text(spec.name).font(.headline)
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").foregroundStyle(ODTheme.muted)
                    }
                    .padding()
                    .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                .tint(.primary)

                Text(spec.description).foregroundStyle(ODTheme.muted)
                if spec.id == "sciCalc" { SciCalcView() }
                if spec.id != "sciCalc" {
                    ForEach(spec.fields) { field in
                        HStack {
                            Text(field.label).frame(width: 150, alignment: .leading)
                            if field.isText {
                                let initial = field.defaultText ?? String(field.defaultValue)
                                TextField(initial, text: Binding(
                                    get: { values[field.id] ?? initial },
                                    set: { values[field.id] = $0 }
                                ))
                                .textFieldStyle(.odField)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            } else if !choices(for: field).isEmpty {
                                let options = choices(for: field)
                                Picker(field.label, selection: Binding(
                                    get: {
                                        let index = Int(Double(values[field.id] ?? "") ?? field.defaultValue)
                                        return max(0, min(options.count - 1, index))
                                    },
                                    set: { values[field.id] = String($0) }
                                )) {
                                    ForEach(Array(options.enumerated()), id: \.offset) { index, label in
                                        Text(label).tag(index)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                TextField(String(field.defaultValue), text: Binding(
                                    get: { values[field.id] ?? String(field.defaultValue) },
                                    set: { values[field.id] = $0 }
                                ))
                                .textFieldStyle(.odField)
                                .keyboardType(.numbersAndPunctuation)
                            }
                            Text(field.unit).foregroundStyle(ODTheme.muted).frame(width: 65, alignment: .leading)
                        }
                    }
                    Divider()
                    Text("Result").font(.headline)
                    ForEach(results) { result in
                        HStack(alignment: .firstTextBaseline) {
                            Text(result.label).foregroundStyle(ODTheme.muted).frame(width: 155, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(result.value).font(.body.monospacedDigit())
                                if !result.note.isEmpty { Text(result.note).font(.caption).foregroundStyle(ODTheme.muted) }
                            }
                        }
                    }
                    if spec.id == "stateVector" { stateVectorExport }
                    }
                }
                .padding().odPanel().padding()
            }
    }

    /// Export controls for the State-vector → GP tool: add the derived orbit to
    /// the catalog (epoch = now, TEME) or share its element set.
    @ViewBuilder private var stateVectorExport: some View {
        let def = BenchTools.stateVectorDefinition(
            rx: numeric["rx"] ?? 0, ry: numeric["ry"] ?? 0, rz: numeric["rz"] ?? 0,
            vx: numeric["vx"] ?? 0, vy: numeric["vy"] ?? 0, vz: numeric["vz"] ?? 0,
            frame: Int(numeric["frame"] ?? 0), epoch: Date())
        Divider()
        if let def {
            VStack(alignment: .leading, spacing: 8) {
                Text("Derived orbit epoch is set to now (TEME). Add it to track it, or share the element set.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
                HStack {
                    Button {
                        store.saveManualSatellite(def)
                        exportMessage = "Added “\(def.name)” to My Satellites (NORAD \(def.norad))."
                    } label: { Label("Add to My Satellites", systemImage: "plus.circle") }
                        .buttonStyle(.borderedProminent)
                    ShareLink(item: Self.elementsText(def)) { Label("Share elements", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                if !exportMessage.isEmpty {
                    Text(exportMessage).font(.caption).foregroundStyle(ODTheme.good)
                }
            }
        } else {
            Text("Enter a valid elliptical (bound) state vector to enable export.")
                .font(.caption).foregroundStyle(ODTheme.warning)
        }
    }

    private static func elementsText(_ d: ManualSatelliteDefinition) -> String {
        """
        \(d.name) — derived from TEME state vector
        Epoch (UTC): \(ODFormat.utc.string(from: d.epoch))
        Inclination: \(String(format: "%.4f", d.inclinationDeg)) deg
        RAAN: \(String(format: "%.4f", d.raanDeg)) deg
        Eccentricity: \(String(format: "%.7f", d.eccentricity))
        Arg. of perigee: \(String(format: "%.4f", d.argumentOfPerigeeDeg)) deg
        Mean anomaly: \(String(format: "%.4f", d.meanAnomalyDeg)) deg
        Mean motion: \(String(format: "%.8f", d.meanMotionRevPerDay)) rev/day
        Generated by OrbitDeck.
        """
    }
}

/// Traditional "receipt-tape" scientific calculator: type an expression, press =,
/// and each entry+result is appended to a scrolling tape. `Ans` recalls the last
/// result. Shares the whitelisted evaluator (degrees/radians, metric prefixes,
/// RF/orbit helpers).
struct SciCalcView: View {
    private struct Entry: Identifiable { let id = UUID(); let expr: String; let value: String }
    @State private var input = ""
    @State private var tape: [Entry] = []
    @State private var ans = 0.0
    @State private var degrees = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .trailing, spacing: 6) {
                        if tape.isEmpty {
                            Text("Enter an expression and press =. Use Ans for the last result.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(tape) { row in
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(row.expr).font(.caption.monospaced()).foregroundStyle(ODTheme.muted)
                                Text("= \(row.value)").font(.title3.monospacedDigit().bold())
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id(row.id)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 200)
                .background(ODTheme.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODTheme.grid))
                .onChange(of: tape.count) { _, _ in
                    if let last = tape.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(ODTheme.warning) }
            HStack {
                TextField("e.g. porb(500),  100k/2.5,  sin(30)+Ans", text: $input)
                    .textFieldStyle(.odField)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { evaluate() }
                Button { evaluate() } label: { Image(systemName: "equal.circle.fill").font(.title2) }
            }
            HStack(spacing: 10) {
                Picker("Angle", selection: $degrees) { Text("DEG").tag(true); Text("RAD").tag(false) }
                    .pickerStyle(.segmented).frame(width: 130)
                Button("Ans") { input += "Ans" }.buttonStyle(.bordered).font(.caption)
                Spacer()
                Button("Clear tape") { tape = []; ans = 0; error = nil }.buttonStyle(.bordered).font(.caption)
            }
            Text("Infix, \(degrees ? "degrees" : "radians"). Metric prefixes (100k, 2.2n, 5M). Ans = last result. Same functions/constants as listed for the Scientific calculator tool.")
                .font(.caption2).foregroundStyle(ODTheme.muted)
        }
    }

    private func evaluate() {
        let expr = input.trimmingCharacters(in: .whitespaces)
        guard !expr.isEmpty else { return }
        do {
            let v = try SafeMathEvaluator().evaluate(expr, variables: ["ans": ans], degrees: degrees)
            ans = v
            tape.append(Entry(expr: expr, value: format(v)))
            input = ""; error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(format: "%.0f", v) }
        return String(format: "%g", v)
    }
}

// MARK: - Tiny BASIC deep parity

private let deepTinyBasicSample = """
10 REM OrbitDeck Tiny BASIC
20 DIM A(12),@(6)
30 DATA 2,3,5,7,11,13
40 FOR I=0 TO 5: READ @(I): NEXT
50 CLS
60 FOR I=0 TO 11
70 A(I)=50+20*SIN(I*30)
80 LINE 120,67,120+95*COS(I*30),67+A(I)*SIN(I*30),3
90 NEXT
100 CIRCLE 120,67,30,5
110 TEXT 70,4,"ORBITDECK BASIC"
120 PRINT "MY GRID DATA: LAT=",MYLAT," LON=",MYLON
130 IF SATOK=0 THEN 160
140 PRINT "SAT ",SATNOR," AZ=",ROUND(SATAZ)," EL=",ROUND(SATEL)
150 PRINT "NEXT AOS IN ",ROUND(AOSIN)," MIN"
160 SHOW
170 END
"""

struct DeepTinyBasicView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var source = deepTinyBasicSample
    @State private var output = ""
    @State private var ops: [BasicGraphicOp] = []
    @State private var status = ""
    @State private var inputText: [String: String] = [:]
    @State private var importing = false
    @State private var shareURL: URL?

    private var prompts: [BasicInputPrompt] { CardSatTinyBasicEngine.inputPrompts(in: source) }

    var body: some View {
        GeometryReader { geo in
            // Single scroll container with padding INSIDE it, so the scroll
            // indicator lives in the outer margin and never overlaps the boxes.
            ScrollView {
                Group {
                    if geo.size.width > 820 {
                        HStack(alignment: .top, spacing: 12) { editor; display }
                    } else {
                        VStack(spacing: 12) { editor; display }
                    }
                }
                .padding()
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    source = text; status = "Opened \(url.lastPathComponent)"
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { run() } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button { output = ""; ops = []; status = "" } label: { Label("Clear", systemImage: "trash") }
                    .buttonStyle(.bordered)
                Spacer()
                Menu {
                    Button { importing = true } label: { Label("Open file…", systemImage: "folder") }
                    Button { source = deepTinyBasicSample } label: { Label("Load sample", systemImage: "doc.text") }
                    ShareLink(item: source, preview: SharePreview("OrbitDeck BASIC source")) {
                        Label("Share source", systemImage: "square.and.arrow.up")
                    }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }
            }
            .labelStyle(.titleAndIcon)

            Text("Program").font(.caption.weight(.bold)).foregroundStyle(ODTheme.accent)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(ODTheme.background)
                .frame(minHeight: 330)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ODTheme.grid))

            if !prompts.isEmpty {
                DisclosureGroup("INPUT values (collected before RUN)") {
                    ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(prompt.label).font(.caption)
                                Text(prompt.variable).font(.caption2.monospaced()).foregroundStyle(ODTheme.muted)
                            }.frame(width: 130, alignment: .leading)
                            TextField(prompt.isString ? "text" : "0", text: Binding(
                                get: { inputText["\(index)-\(prompt.variable)"] ?? "" },
                                set: { inputText["\(index)-\(prompt.variable)"] = $0 }
                            ))
                            .textFieldStyle(.odField)
                            .keyboardType(prompt.isString ? .default : .numbersAndPunctuation)
                        }
                    }
                }
            }

            Text("Output").font(.caption.weight(.bold)).foregroundStyle(ODTheme.accent)
            ScrollView {
                Text(output.isEmpty ? "(no output)" : output)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(output.isEmpty ? ODTheme.muted : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 125).odPanel()
            Text(status).font(.caption).foregroundStyle(ODTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display · 240 × 135").font(.caption.weight(.bold)).foregroundStyle(ODTheme.accent)
            Canvas { context, size in
                let scale = min(size.width / 240, size.height / 135)
                let ox = (size.width - 240 * scale) / 2, oy = (size.height - 135 * scale) / 2
                context.fill(rectPath(CGRect(x: ox, y: oy, width: 240 * scale, height: 135 * scale)), with: .color(.black))
                for op in ops {
                    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
                    let col = Color(hex: CardSatTinyBasicEngine.palette[max(0, min(CardSatTinyBasicEngine.palette.count - 1, op.color))])
                    switch op.kind {
                    case .cls:
                        context.fill(rectPath(CGRect(x: ox, y: oy, width: 240 * scale, height: 135 * scale)), with: .color(.black))
                    case .pset:
                        if op.values.count >= 2 { let q = p(op.values[0], op.values[1]); context.fill(rectPath(CGRect(x: q.x, y: q.y, width: max(1, scale), height: max(1, scale))), with: .color(col)) }
                    case .line:
                        if op.values.count >= 4 { var path = Path(); path.move(to: p(op.values[0], op.values[1])); path.addLine(to: p(op.values[2], op.values[3])); context.stroke(path, with: .color(col), lineWidth: max(1, scale)) }
                    case .circle:
                        if op.values.count >= 3 { let q = p(op.values[0], op.values[1]), rr = op.values[2] * scale; context.stroke(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(col), lineWidth: max(1, scale)) }
                    case .text:
                        if op.values.count >= 2 { context.draw(Text(op.text).font(.system(size: max(7, 5 * scale), design: .monospaced)).foregroundStyle(.white), at: p(op.values[0], op.values[1]), anchor: .topLeading) }
                    case .show: break
                    }
                }
            }
            .aspectRatio(240 / 135, contentMode: .fit).frame(minHeight: 300).odPanel()

            Text("Supports numeric and A$–Z$ string variables, @()/named arrays with a shared 2048-element budget, DATA/READ/RESTORE, mixed pre-run INPUT, text functions, constants/geometry helpers, PASSAOS/PASSLOS/PASSMAX, ON…GOTO, arbitrary IF…THEN statements, degree trig, SATSEL/TXSEL, LPRINT, graphics, and sandboxed files. Execution is bounded by statement and wall-clock limits.")
                .font(.caption).foregroundStyle(ODTheme.muted)
            Text("BASIC files are confined to OrbitDeck’s Application Support/Basic directory; programs cannot supply paths or escape that sandbox.")
                .font(.caption).foregroundStyle(ODTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor private func run() {
        let numericInputs = prompts.enumerated().compactMap { index, prompt -> Double? in
            guard !prompt.isString else { return nil }
            return Double(inputText["\(index)-\(prompt.variable)"] ?? "0") ?? 0
        }
        let stringInputs = prompts.enumerated().compactMap { index, prompt -> String? in
            guard prompt.isString else { return nil }
            return inputText["\(index)-\(prompt.variable)"] ?? ""
        }
        let host = TinyBasicHostContext(observer: store.preferences.observer,
                                        satellites: store.satellites,
                                        selectedNorad: store.preferences.selectedNorad,
                                        favorites: store.preferences.favorites,
                                        weather: store.spaceWeather,
                                        minimumElevation: store.preferences.minElevation,
                                        now: .now)
        do {
            let result = try CardSatTinyBasicEngine().run(source, inputs: numericInputs, stringInputs: stringInputs, host: host, fileDirectory: basicDirectory)
            output = result.output.joined(separator: "\n")
            ops = result.graphics
            status = "Ran \(result.steps) statement(s); \(result.graphics.count) graphics call(s)."
        } catch {
            output = "?\(error.localizedDescription)"
            status = error.localizedDescription
        }
    }

    private var basicDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OrbitDeck", isDirectory: true).appendingPathComponent("Basic", isDirectory: true)
    }
}

// MARK: - Learn deep parity

private struct LearnGeoPoint: Identifiable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
}

private struct LearnEclipseSample: Identifiable {
    let id: Date
    let date: Date
    let sunlit: Bool
}

private struct LearnOrientationPoint: Identifiable {
    let id: Int
    let longitude: Double
    let latitude: Double
}

private enum DeepLearnTopic: String, CaseIterable, Identifiable {
    case kepler = "Kepler / equal area"
    case anomalies = "Orbital anomalies"
    case speed = "Orbital speed"
    case transfer = "Transfers"
    case elementAge = "Element age"
    case decay = "Decay"
    case horizon = "Horizon & footprint"
    case slant = "Slant range"
    case drift = "Track drift"
    case precession = "Precession"
    case orientation = "RAAN / perigee"
    case constellation = "Constellation"
    case coverage = "24 h coverage"
    case eclipse = "Sunlight / eclipse"
    case eclipseTimeline = "Eclipse timeline"
    case pointing = "Pointing"
    case grid = "Grid squares"
    case doppler = "Doppler"
    case duplex = "Duplex practice"
    case transponder = "Transponder"
    case link = "Link budget"
    case antenna = "Antenna pattern"
    var id: String { rawValue }
}

struct DeepLearnView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var topic: DeepLearnTopic = .kepler
    @State private var altitude = 500.0
    @State private var altitude2 = 1200.0
    @State private var elevation = 20.0
    @State private var frequency = 145.8
    @State private var rangeRate = -5.0
    @State private var eirp = 27.0
    @State private var rxGain = 6.0
    @State private var sensitivity = -120.0
    @State private var eccentricity = 0.25
    @State private var anomaly = 45.0
    @State private var planeChange = 10.0
    @State private var raan = 0.0
    @State private var argumentOfPerigee = 0.0
    @State private var gainDBi = 10.0
    @State private var uplink = 145.95
    @State private var downlink = 435.15
    @State private var inverted = true
    @State private var coveragePoints: [LearnGeoPoint] = []
    @State private var eclipseSamples: [LearnEclipseSample] = []
    @State private var pointingPath: [SkyPoint] = []
    @State private var learnStatus = ""
    @State private var gridLatitude = 39.93
    @State private var gridLongitude = -74.89
    @State private var solarIndex = 1.0
    @State private var duplexOffsetKHz = 5.0
    @State private var handoutURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Lesson", selection: $topic) { ForEach(DeepLearnTopic.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                if let lab = store.preferences.labOrbit {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Shared OSCARLOCATOR lab orbit").font(.headline)
                            Text(String(format: "%.0f km • e %.3f • i %.1f° • Ω %.1f° • ω %.1f° • M %.1f°", lab.altitudeKm, lab.eccentricity, lab.inclinationDeg, lab.raanDeg, lab.argumentOfPerigeeDeg, lab.meanAnomalyDeg)).font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                        }
                        Spacer()
                        Button("Use throughout Learn") {
                            altitude = lab.altitudeKm
                            eccentricity = lab.eccentricity
                            planeChange = lab.inclinationDeg
                            raan = lab.raanDeg
                            argumentOfPerigee = lab.argumentOfPerigeeDeg
                            anomaly = lab.meanAnomalyDeg
                            altitude2 = max(100, lab.altitudeKm * (1 + lab.eccentricity))
                            learnStatus = "Loaded all six shared orbital elements into Learn."
                        }
                    }.padding().odPanel()
                }
                lesson.padding().odPanel()
                HStack {
                    Button("Prepare 4-page classroom handout") {
                        do { handoutURL = try OrbitExportService.temporaryFile(name: "OrbitDeck-Classroom-Handout.pdf", data: OrbitExportService.learnHandoutPDF(observer: store.preferences.observer, labOrbit: store.preferences.labOrbit)) }
                        catch { learnStatus = error.localizedDescription }
                    }.buttonStyle(.bordered)
                    if let handoutURL { ShareLink(item: handoutURL) { Label("Share PDF", systemImage: "square.and.arrow.up") } }
                }
                if !learnStatus.isEmpty { Text(learnStatus).font(.caption).foregroundStyle(ODTheme.good) }
                Text("The teaching suite includes coverage, eclipse-timeline, pointing, duplex, decay, grid-square, precession, and orbital-orientation concepts. The shared OSCARLOCATOR lab orbit transfers altitude, eccentricity, inclination, RAAN, argument of perigee, and mean anomaly into Learn, and the classroom handout records all six elements.")
                    .font(.caption).foregroundStyle(ODTheme.muted)
            }.padding()
        }
    }

    @ViewBuilder private var lesson: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch topic {
            case .kepler:
                Text("Kepler’s second law: equal areas in equal times").font(.title2.bold())
                slider("Eccentricity", $eccentricity, 0...0.8, "")
                slider("Mean anomaly", $anomaly, 0...360, "°")
                let e = LearnMath.eccentricAnomaly(meanAnomalyRad: anomaly * .pi / 180, eccentricity: eccentricity)
                let nu = LearnMath.trueAnomaly(meanAnomalyDeg: anomaly, eccentricity: eccentricity)
                metric("Eccentric anomaly", String(format: "%.1f°", e * 180 / .pi))
                metric("True anomaly", String(format: "%.1f°", nu))
                orbitChart
                Text("The marker advances by mean anomaly—uniform in time—not by true anomaly. It therefore moves faster near perigee and slower near apogee while sweeping equal areas in equal time.").foregroundStyle(ODTheme.muted)
            case .anomalies:
                Text("Mean, eccentric, and true anomaly").font(.title2.bold())
                slider("Eccentricity", $eccentricity, 0...0.85, "")
                slider("Mean anomaly", $anomaly, 0...360, "°")
                let e = LearnMath.eccentricAnomaly(meanAnomalyRad: anomaly * .pi / 180, eccentricity: eccentricity)
                metric("Mean anomaly M", String(format: "%.2f°", anomaly))
                metric("Eccentric anomaly E", String(format: "%.2f°", e * 180 / .pi))
                metric("True anomaly ν", String(format: "%.2f°", LearnMath.trueAnomaly(meanAnomalyDeg: anomaly, eccentricity: eccentricity)))
                Text("M is the uniform clock angle. E solves Kepler’s equation M = E − e·sin(E). ν is the spacecraft’s geometric angle from perigee.").foregroundStyle(ODTheme.muted)
            case .speed:
                Text("Why low satellites move faster").font(.title2.bold())
                slider("Circular altitude", $altitude, 100...40000, "km")
                metric("Orbital speed", String(format: "%.3f km/s", LearnMath.circularSpeed(altitudeKm: altitude)))
                metric("Period", String(format: "%.1f min", LearnMath.circularPeriodMinutes(altitudeKm: altitude)))
                Chart(Array(stride(from: 100, through: 40000, by: 500).enumerated()).map { GraphPoint(id: $0.offset, x: Double($0.element), y: LearnMath.circularSpeed(altitudeKm: Double($0.element))) }) { p in if let y=p.y { LineMark(x:.value("Altitude",p.x),y:.value("Speed",y)) } }.frame(height:260)
            case .transfer:
                Text("Hohmann transfers and plane changes").font(.title2.bold())
                slider("Initial altitude", $altitude, 100...36000, "km")
                slider("Final altitude", $altitude2, 100...42000, "km")
                slider("Plane change", $planeChange, 0...90, "°")
                let h = LearnMath.hohmannTransfer(r1Km: LearnMath.earthRadiusKm + altitude, r2Km: LearnMath.earthRadiusKm + altitude2)
                let speed = LearnMath.circularSpeed(altitudeKm: altitude2)
                metric("Transfer Δv", String(format: "%.3f km/s", h.total))
                metric("Transfer time", String(format: "%.1f min", h.minutes))
                metric("Plane-change Δv", String(format: "%.3f km/s", LearnMath.planeChangeDeltaV(speedKmS: speed, angleDeg: planeChange)))
                Text("Plane changes are cheapest where orbital speed is lowest; large inclination changes can cost more Δv than raising an orbit.").foregroundStyle(ODTheme.muted)
            case .elementAge:
                Text("Why element age matters").font(.title2.bold())
                if let sat = store.selectedSatellite {
                    let trust = FeatureEngine.elementTrust(sat)
                    metric("Satellite", sat.name)
                    metric("Element age", String(format: "%.2f days", trust.ageDays))
                    metric("Planning level", trust.level)
                    Text(trust.note).foregroundStyle(ODTheme.muted)
                    Text("Drag, maneuvers, and model error accumulate primarily along track. Precision Doppler and antenna pointing should use fresher elements than broad pass planning.").foregroundStyle(ODTheme.muted)
                } else { Text("Select a satellite first.") }
            case .decay:
                Text("Atmospheric decay and why perigee matters").font(.title2.bold())
                if let sat = store.selectedSatellite {
                    Picker("Solar activity", selection: $solarIndex) {
                        Text("Low").tag(0.0); Text("Mean").tag(1.0); Text("High").tag(2.0)
                    }.pickerStyle(.segmented)
                    let estimate = LearnMath.decayEstimate(meanMotion: sat.meanMotionRevPerDay, eccentricity: sat.eccentricity, bstar: sat.bstar, solarIndex: Int(solarIndex))
                    metric("Perigee", String(format: "%.0f km", sat.perigeeKm))
                    metric("B*", String(format: "%.6g", sat.bstar))
                    metric("Anchor", estimate.source)
                    metric("Lifetime", estimate.days < 0 ? "no usable data" : estimate.days.isInfinite ? "effectively stable" : estimate.days < 365.25 ? String(format: "%.0f days", estimate.days) : String(format: "%.1f years", estimate.days/365.25))
                    Text("Drag grows rapidly as perigee enters denser atmosphere. Eccentric satellites spend only a small part of each orbit near perigee, so the decay model includes that dwell-time effect rather than treating the entire orbit as if it were at perigee.").foregroundStyle(ODTheme.muted)
                } else { Text("Select a satellite first.") }
            case .horizon:
                Text("How altitude expands the footprint").font(.title2.bold())
                slider("Altitude", $altitude, 100...40000, "km")
                metric("Horizon radius", String(format: "%.0f km", LearnMath.horizonRadiusKm(altitudeKm: altitude)))
                metric("Angular radius", String(format: "%.1f°", LearnMath.horizonRadiusKm(altitudeKm: altitude) / LearnMath.earthRadiusKm * 180 / .pi))
            case .slant:
                Text("Why range changes strongly near the horizon").font(.title2.bold())
                slider("Altitude", $altitude, 100...2000, "km")
                slider("Elevation", $elevation, 0...90, "°")
                metric("Slant range", String(format: "%.0f km", LearnMath.slantRangeKm(altitudeKm: altitude, elevationDeg: elevation)))
                Chart((0...90).enumerated().map { GraphPoint(id:$0.offset,x:Double($0.element),y:LearnMath.slantRangeKm(altitudeKm:altitude,elevationDeg:Double($0.element))) }) { p in if let y=p.y { LineMark(x:.value("Elevation",p.x),y:.value("Range",y)) } }.frame(height:260)
            case .drift:
                Text("Earth turns beneath each orbit").font(.title2.bold())
                slider("Altitude", $altitude, 100...40000, "km")
                metric("Orbital period", String(format:"%.1f min",LearnMath.circularPeriodMinutes(altitudeKm:altitude)))
                metric("Westward shift", String(format:"%.1f° / orbit",LearnMath.trackDriftDegrees(altitudeKm:altitude)))
            case .precession:
                Text("J2 precession: Earth is not perfectly spherical").font(.title2.bold())
                slider("Altitude", $altitude, 200...40000, "km")
                slider("Inclination", $planeChange, 0...180, "°")
                slider("Eccentricity", $eccentricity, 0...0.7, "")
                let mm = 1440 / LearnMath.circularPeriodMinutes(altitudeKm: altitude)
                let rates = LearnMath.j2Rates(meanMotionRevDay: mm, inclinationDeg: planeChange, eccentricity: eccentricity)
                metric("RAAN drift", String(format: "%+.3f°/day", rates.nodeDegDay))
                metric("Perigee drift", String(format: "%+.3f°/day", rates.perigeeDegDay))
                metric("Sun-sync target", String(format: "error %+.3f°/day", rates.nodeDegDay - 0.9856))
                Text("J2 rotates the orbital plane and the line of apsides. Near-polar retrograde LEOs can use this naturally to keep the orbital plane aligned with the Sun.").foregroundStyle(ODTheme.muted)
            case .orientation:
                Text("RAAN, argument of perigee, and position").font(.title2.bold())
                slider("Inclination", $planeChange, 0...180, "°")
                slider("RAAN Ω", $raan, 0...360, "°")
                slider("Arg. perigee ω", $argumentOfPerigee, 0...360, "°")
                slider("Eccentricity", $eccentricity, 0...0.8, "")
                slider("Mean anomaly M", $anomaly, 0...360, "°")
                Chart(orientationPath) { point in
                    LineMark(
                        x: .value("Inertial longitude", point.longitude),
                        y: .value("Geocentric latitude", point.latitude),
                        series: .value("Orbit", "Path")
                    )
                }
                .chartXScale(domain: -180...180)
                .chartYScale(domain: -90...90)
                .frame(height: 260)
                let perigee = orientationPoint(trueAnomalyDeg: 0)
                let currentNu = LearnMath.trueAnomaly(meanAnomalyDeg: anomaly, eccentricity: eccentricity)
                let current = orientationPoint(trueAnomalyDeg: currentNu)
                metric("Ascending node", String(format: "Ω ≈ %.1f° inertial longitude", normalized360(raan)))
                metric("Perigee point", String(format: "%+.1f° lat / %+.1f° lon", perigee.latitude, perigee.longitude))
                metric("Current ν", String(format: "%.1f°", currentNu))
                metric("Current point", String(format: "%+.1f° lat / %+.1f° lon", current.latitude, current.longitude))
                Text("RAAN rotates the entire orbital plane around Earth’s spin axis. Argument of perigee rotates the ellipse within that plane, moving the low/high apsides without changing the plane itself. Mean anomaly advances the spacecraft around the ellipse. This is an inertial orientation sketch: Earth rotation and J2 drift are intentionally omitted so each element’s role stays visible.").foregroundStyle(ODTheme.muted)
            case .constellation:
                Text("Continuous-coverage intuition").font(.title2.bold())
                slider("Altitude", $altitude, 200...36000, "km")
                slider("Minimum elevation", $elevation, 0...30, "°")
                let n = LearnMath.constellationSatellites(altitudeKm: altitude, minimumElevationDeg: elevation)
                metric("Idealized ring minimum", n == Int.max ? "—" : "~\(n) satellites")
                Text("This is a geometry-only ring estimate. Real constellations need multiple planes, overlap, phasing, capacity, and outage margin.").foregroundStyle(ODTheme.muted)
            case .coverage:
                Text("Accumulated footprint over 24 hours").font(.title2.bold())
                if let sat = store.selectedSatellite {
                    metric("Satellite", sat.name)
                    Button("Compute 24 h coverage") { Task { await computeCoverage(sat) } }.buttonStyle(.borderedProminent)
                    if coveragePoints.isEmpty {
                        Text(learnStatus.isEmpty ? "Compute to sample the satellite sub-point every three minutes." : learnStatus).foregroundStyle(ODTheme.muted)
                    } else {
                        coverageMap
                        Text("Each point is a three-minute sub-satellite sample. Polar/high-inclination orbits spread coverage across latitude; low-inclination orbits remain confined to a belt.").foregroundStyle(ODTheme.muted)
                    }
                } else { Text("Select a satellite first.") }
            case .eclipse:
                Text("Beta angle and eclipse seasons").font(.title2.bold())
                slider("Altitude", $altitude, 100...40000, "km")
                let threshold = LearnMath.eclipseBetaThresholdDeg(altitudeKm: altitude)
                metric("Eclipse possible", String(format:"|β| < %.1f°",threshold))
                metric("Continuous sunlight", String(format:"|β| ≥ %.1f°",threshold))
                Text("When the orbital plane is tilted far enough toward the Sun, Earth’s shadow misses the orbit entirely.").foregroundStyle(ODTheme.muted)
            case .eclipseTimeline:
                Text("Sunlight and shadow over several orbits").font(.title2.bold())
                if let sat = store.selectedSatellite {
                    Button("Compute next six orbits") { Task { await computeEclipseTimeline(sat) } }.buttonStyle(.borderedProminent)
                    if !eclipseSamples.isEmpty {
                        Chart(eclipseSamples) { sample in
                            LineMark(x: .value("Time", sample.date), y: .value("Sunlit", sample.sunlit ? 1 : 0), series: .value("State", "Sunlight"))
                        }.chartYScale(domain: -0.1...1.1).frame(height: 220)
                        metric("Samples", "\(eclipseSamples.count)")
                    } else { Text(learnStatus.isEmpty ? "Compute a timeline from the propagated Sun/shadow state." : learnStatus).foregroundStyle(ODTheme.muted) }
                } else { Text("Select a satellite first.") }
            case .pointing:
                Text("Pointing through the next visible pass").font(.title2.bold())
                if let sat = store.selectedSatellite {
                    Button("Load next pass") { Task { await computePointing(sat) } }.buttonStyle(.borderedProminent)
                    if !pointingPath.isEmpty {
                        Chart(pointingPath) { p in
                            LineMark(x: .value("Time", p.date), y: .value("Elevation", p.elevation))
                        }.frame(height: 230)
                        metric("Start azimuth", String(format: "%.0f°", pointingPath.first?.azimuth ?? 0))
                        metric("End azimuth", String(format: "%.0f°", pointingPath.last?.azimuth ?? 0))
                    } else { Text(learnStatus.isEmpty ? "Load a pass to see how antenna elevation changes from AOS through TCA to LOS." : learnStatus).foregroundStyle(ODTheme.muted) }
                } else { Text("Select a satellite first.") }
            case .grid:
                Text("Maidenhead grid squares").font(.title2.bold())
                slider("Latitude", $gridLatitude, -90...90, "°")
                slider("Longitude", $gridLongitude, -180...180, "°")
                metric("4-character grid", FeatureEngine.latLonToGrid4(latitude: gridLatitude, longitude: gridLongitude))
                metric("Your QTH", FeatureEngine.latLonToGrid4(latitude: store.preferences.observer.latitude, longitude: store.preferences.observer.longitude))
                Text("Maidenhead turns latitude/longitude into compact radio locators. Four-character fields are convenient for broad satellite footprint exercises; six-character locators add local precision.").foregroundStyle(ODTheme.muted)
            case .doppler:
                Text("Range rate becomes frequency shift").font(.title2.bold())
                slider("Frequency", $frequency, 29...2400, "MHz")
                slider("Range rate", $rangeRate, -8...8, "km/s")
                metric("One-way Doppler", String(format:"%+.0f Hz",LearnMath.dopplerHz(freqMHz:frequency,rangeRateKmS:rangeRate)))
                Chart((-80...80).enumerated().map { GraphPoint(id:$0.offset,x:Double($0.element)/10,y:LearnMath.dopplerHz(freqMHz:frequency,rangeRateKmS:Double($0.element)/10)) }) { p in if let y=p.y { LineMark(x:.value("Range rate",p.x),y:.value("Shift",y)) } }.frame(height:260)
            case .transponder:
                Text("Linear transponder passband mapping").font(.title2.bold())
                slider("Uplink center", $uplink, 100...2500, "MHz")
                slider("Downlink center", $downlink, 100...2500, "MHz")
                Toggle("Inverting transponder", isOn: $inverted)
                slider("Dial offset", $elevation, -50...50, "kHz")
                let mapped = inverted ? -elevation : elevation
                metric("Uplink", String(format:"%.6f MHz",uplink + elevation/1000))
                metric("Downlink", String(format:"%.6f MHz",downlink + mapped/1000))
                Text(inverted ? "Moving up in frequency on the uplink moves down by the same passband offset on the downlink." : "Non-inverting transponders preserve the passband offset direction.").foregroundStyle(ODTheme.muted)
            case .link:
                Text("Free-space link budget sandbox").font(.title2.bold())
                slider("Frequency", $frequency, 29...2400, "MHz")
                slider("Range", $altitude, 100...5000, "km")
                slider("TX EIRP", $eirp, -10...50, "dBm")
                slider("RX gain", $rxGain, -5...25, "dBi")
                slider("Sensitivity", $sensitivity, -145 ... -80, "dBm")
                let loss=LearnMath.fsplDb(rangeKm:altitude,freqMHz:frequency),rx=eirp-loss+rxGain,margin=rx-sensitivity
                metric("Path loss",String(format:"%.1f dB",loss));metric("RX power",String(format:"%.1f dBm",rx));metric("Margin",String(format:"%+.1f dB",margin))
            case .duplex:
                Text("Full-duplex linear-transponder tuning").font(.title2.bold())
                slider("Range rate", $rangeRate, -8...8, "km/s")
                slider("Downlink offset", $duplexOffsetKHz, -20...20, "kHz")
                if let tp = store.selectedSatellite?.transponders.first(where: { $0.isLinear && $0.uplinkCenter > 0 && $0.downlinkCenter > 0 }) {
                    let offsetHz = duplexOffsetKHz * 1000
                    let parked = Double(tp.downlinkCenter) + offsetHz
                    let ideal = LearnMath.fixedDownlinkUplinkHz(downlinkCenterHz: tp.downlinkCenter, uplinkCenterHz: tp.uplinkCenter, downlinkOffsetHz: offsetHz, rangeRateKmS: rangeRate, inverted: tp.invert)
                    metric("Transponder", tp.description.isEmpty ? tp.kind : tp.description)
                    metric("Passband", tp.invert ? "inverting" : "non-inverting")
                    metric("Park receiver", String(format: "%.6f MHz", parked/1e6))
                    metric("Tune transmitter", String(format: "%.6f MHz", Double(ideal)/1e6))
                    metric("TX offset", String(format: "%+.0f Hz", Double(ideal - tp.uplinkCenter)))
                    Text("For linear satellites, full-duplex operating means listening to your own signal while correcting the transmitting leg. The sign reverses across the pass as range rate changes.").foregroundStyle(ODTheme.muted)
                } else {
                    Text("Select a satellite with a loaded linear transponder to practice fixed-downlink tuning.").foregroundStyle(ODTheme.muted)
                }
            case .antenna:
                Text("Gain and beamwidth tradeoff").font(.title2.bold())
                slider("Antenna gain", $gainDBi, 0...30, "dBi")
                let bw = LearnMath.antennaBeamwidthApprox(gainDBi: gainDBi)
                metric("Approx. HPBW", String(format:"%.1f°",bw))
                Chart((-900...900).enumerated().map { item -> GraphPoint in
                    let angle=Double(item.element)/10, sigma=max(1,bw/2.355), level=exp(-0.5*pow(angle/sigma,2)); return GraphPoint(id:item.offset,x:angle,y:level)
                }) { p in if let y=p.y { LineMark(x:.value("Angle",p.x),y:.value("Relative gain",y)) } }.frame(height:260)
                Text("Higher gain concentrates energy into a narrower beam, improving link margin at the cost of more demanding pointing.").foregroundStyle(ODTheme.muted)
            }
        }
    }

    private var orientationPath: [LearnOrientationPoint] {
        stride(from: 0.0, through: 360.0, by: 3.0).enumerated().map { item in
            let p = orientationPoint(trueAnomalyDeg: item.element)
            return LearnOrientationPoint(id: item.offset, longitude: p.longitude, latitude: p.latitude)
        }
    }

    private func orientationPoint(trueAnomalyDeg: Double) -> (longitude: Double, latitude: Double) {
        let omega = raan * .pi / 180
        let inc = planeChange * .pi / 180
        let u = (argumentOfPerigee + trueAnomalyDeg) * .pi / 180
        let x = cos(omega) * cos(u) - sin(omega) * sin(u) * cos(inc)
        let y = sin(omega) * cos(u) + cos(omega) * sin(u) * cos(inc)
        let z = sin(u) * sin(inc)
        let latitude = asin(max(-1, min(1, z))) * 180 / .pi
        let longitude = normalized180(atan2(y, x) * 180 / .pi)
        return (longitude, latitude)
    }

    private func normalized180(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return value
    }

    private func normalized360(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    private var coverageMap: some View {
        Canvas { context, size in
            var grid = Path()
            for lon in stride(from: -180.0, through: 180.0, by: 30.0) {
                let x = (lon + 180) / 360 * size.width
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for lat in stride(from: -90.0, through: 90.0, by: 30.0) {
                let y = (90 - lat) / 180 * size.height
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(ODTheme.grid), lineWidth: 0.5)
            for p in coveragePoints {
                let x = (p.longitude + 180) / 360 * size.width
                let y = (90 - p.latitude) / 180 * size.height
                context.fill(Path(ellipseIn: CGRect(x: x-1.5, y: y-1.5, width: 3, height: 3)), with: .color(ODTheme.accent.opacity(0.75)))
            }
        }.frame(height: 260).background(ODTheme.panel)
    }

    @MainActor private func computeCoverage(_ sat: SatelliteRecord) async {
        learnStatus = "Computing…"
        do {
            var points: [LearnGeoPoint] = []
            let start = Date()
            for minute in stride(from: 0.0, through: 1440.0, by: 3.0) {
                let p = try OrbitPredictor.subpoint(sat, at: start.addingTimeInterval(minute*60))
                points.append(.init(latitude: p.latitude, longitude: p.longitude))
            }
            coveragePoints = points; learnStatus = "\(points.count) samples"
        } catch { learnStatus = error.localizedDescription }
    }

    @MainActor private func computeEclipseTimeline(_ sat: SatelliteRecord) async {
        learnStatus = "Computing…"
        do {
            let start = Date(), duration = max(1, sat.periodMinutes) * 6 * 60
            var samples: [LearnEclipseSample] = []
            var t = 0.0
            while t <= duration {
                let date = start.addingTimeInterval(t)
                let look = try OrbitPredictor.look(sat, observer: store.preferences.observer, at: date)
                samples.append(.init(id: date, date: date, sunlit: look.sunlit))
                t += 60
            }
            eclipseSamples = samples; learnStatus = "\(samples.count) one-minute samples"
        } catch { learnStatus = error.localizedDescription }
    }

    @MainActor private func computePointing(_ sat: SatelliteRecord) async {
        learnStatus = "Finding pass…"
        do {
            let passes = try OrbitPredictor.predictPasses(sat, observer: store.preferences.observer, minElevation: store.preferences.minElevation, maxCount: 1, horizonDays: 3)
            guard let pass = passes.first else { learnStatus = "No qualifying pass in the next three days."; return }
            pointingPath = try OrbitPredictor.skyPath(sat, observer: store.preferences.observer, pass: pass, step: 20)
            learnStatus = "Max elevation \(String(format: "%.0f°", pass.maxElevation))"
        } catch { learnStatus = error.localizedDescription }
    }

    private var orbitChart: some View {
        let a = 1.0, b = sqrt(max(0.001, 1 - eccentricity*eccentricity)), focus = eccentricity
        let points = (0...180).map { i -> GraphPoint in let t = Double(i) * 2 * .pi / 180; return GraphPoint(id:i,x:a*cos(t)-focus,y:b*sin(t)) }
        let nu = LearnMath.trueAnomaly(meanAnomalyDeg: anomaly, eccentricity: eccentricity) * .pi / 180
        let r=(1-eccentricity*eccentricity)/(1+eccentricity*cos(nu))
        let sx=r*cos(nu),sy=r*sin(nu)
        return Chart {
            ForEach(points) { p in if let y=p.y { LineMark(x:.value("x",p.x),y:.value("y",y)) } }
            PointMark(x:.value("Spacecraft",sx),y:.value("Spacecraft",sy)).symbolSize(80).foregroundStyle(ODTheme.warning)
            PointMark(x:.value("Earth",0),y:.value("Earth",0)).symbolSize(100).foregroundStyle(ODTheme.accent)
        }.chartXScale(domain:-1.8...1.8).chartYScale(domain:-1.2...1.2).frame(height:280)
    }

    @ViewBuilder private func slider(_ label:String,_ value:Binding<Double>,_ range:ClosedRange<Double>,_ unit:String)->some View {
        VStack(alignment:.leading){Text("\(label): \(value.wrappedValue,specifier:"%.1f") \(unit)").font(.caption.monospacedDigit());Slider(value:value,in:range)}
    }
    private func metric(_ label:String,_ value:String)->some View { HStack{Text(label).foregroundStyle(ODTheme.muted);Spacer();Text(value).font(.body.monospacedDigit())} }
}
