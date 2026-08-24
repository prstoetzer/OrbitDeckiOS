import SwiftUI

// MARK: - Daily schedule

private struct ScheduleEntry: Identifiable {
    let id: String
    let satelliteID: UInt
    let name: String
    let pass: PredictedPass
}

/// A day-by-day agenda of every favorite satellite's passes, ordered by AOS time.
/// Shows the past 7 days and extends forward automatically as the operator scrolls
/// past the last populated day. All times are UTC (ham-satellite convention).
struct ScheduleView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var entries: [ScheduleEntry] = []
    @State private var daysForward = 7
    @State private var loading = false
    @State private var didInitialScroll = false

    private let daysBack = 7
    private let maxDaysForward = 60

    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }

    private var favorites: [SatelliteRecord] {
        store.satellites.filter { store.preferences.favorites.contains($0.id) }
    }

    private var days: [Date] {
        let base = utcCalendar.startOfDay(for: Date()).addingTimeInterval(-Double(daysBack) * 86400)
        return (0...(daysBack + daysForward)).compactMap { utcCalendar.date(byAdding: .day, value: $0, to: base) }
    }

    private func entries(on day: Date) -> [ScheduleEntry] {
        entries.filter { utcCalendar.isDate($0.pass.aos, inSameDayAs: day) }
            .sorted { $0.pass.aos < $1.pass.aos }
    }

    private var scheduleKey: String {
        let favs = favorites.map { String($0.id) }.sorted().joined(separator: ",")
        // Use the ~1 km stable key: while following the device, the 3-decimal
        // coarseKey jitters and kept restarting this multi-second load before it
        // finished, so later days never populated ("stops partway").
        return "\(favs)-\(store.preferences.observer.stableKey)-\(store.preferences.minElevation)-\(daysForward)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if favorites.isEmpty {
                    Section {
                        Text("Mark satellites as favorites (★) to see their passes here.")
                            .foregroundStyle(ODTheme.muted)
                    }
                } else {
                    ForEach(days, id: \.self) { day in
                        Section {
                            // Day label as a normal (non-sticky) row so it always
                            // renders cleanly below the navigation bar rather than
                            // tucking under it like a sticky section header.
                            Text(dayLabel(day))
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(ODTheme.accent)
                                .id(day)
                            let dayEntries = entries(on: day)
                            if dayEntries.isEmpty {
                                Text(loading ? "Computing…" : "No favorite passes.")
                                    .font(.caption).foregroundStyle(ODTheme.muted)
                            } else {
                                ForEach(dayEntries) { entry in scheduleRow(entry) }
                            }
                        }
                        .onAppear {
                            if day == days.last, daysForward < maxDaysForward { daysForward += 7 }
                        }
                    }
                }
            }
            // Open at the next pass (the earlier part of today and the past week
            // sit above, scrollable; the rest extends below). Pin only after the
            // first load finishes, so the freshly-populated rows have laid out.
            .onChange(of: loading) { _, isLoading in
                guard !isLoading, !didInitialScroll, !favorites.isEmpty else { return }
                didInitialScroll = true
                pinToNextPass(proxy)
            }
        }
        .task(id: scheduleKey) { await load() }
    }

    /// The first pass at or after the current instant — the row the schedule opens
    /// to. Falls back to the start of today if every loaded pass is in the past.
    private var firstUpcomingTarget: AnyHashable {
        let now = Date()
        if let next = entries.filter({ $0.pass.aos >= now }).min(by: { $0.pass.aos < $1.pass.aos }) {
            return AnyHashable(next.id)
        }
        return AnyHashable(utcCalendar.startOfDay(for: now))
    }

    /// Scroll the next upcoming pass to the top. Deferred (and repeated once) so the
    /// pin lands after the just-populated rows have laid out.
    private func pinToNextPass(_ proxy: ScrollViewProxy) {
        let target = firstUpcomingTarget
        for delay in [0.05, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.none) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }

    @ViewBuilder private func scheduleRow(_ entry: ScheduleEntry) -> some View {
        HStack(spacing: 10) {
            Button { store.select(entry.satelliteID) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .foregroundStyle(entry.satelliteID == store.selectedSatellite?.id ? ODTheme.accent : .primary)
                            .lineLimit(1)
                        Text("\(ODFormat.compass(entry.pass.aosAzimuth)) → \(ODFormat.compass(entry.pass.losAzimuth)) · \(ODFormat.duration(entry.pass.duration))")
                            .font(.caption).foregroundStyle(ODTheme.muted)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ODFormat.primaryClock(entry.pass.aos)).font(.body.monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("\(ODFormat.secondaryClock(entry.pass.aos)) · max \(ODFormat.angle(entry.pass.maxElevation))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)

            if entry.pass.aos > Date(), let satellite = store.satellites.first(where: { $0.id == entry.satelliteID }) {
                PassAlarmButton(satellite: satellite, pass: entry.pass,
                                observer: store.preferences.observer,
                                leadMinutes: store.preferences.passAlarmLeadMinutes ?? 10)
            } else {
                PassAlarmUnavailable()
            }
        }
        .id(entry.id)
    }

    private func dayLabel(_ day: Date) -> String {
        let now = utcCalendar.startOfDay(for: Date())
        let dateText = Self.dayFormatter.string(from: day)
        if utcCalendar.isDate(day, inSameDayAs: now) { return "Today · \(dateText) UTC" }
        if let tomorrow = utcCalendar.date(byAdding: .day, value: 1, to: now), utcCalendar.isDate(day, inSameDayAs: tomorrow) { return "Tomorrow · \(dateText)" }
        if let yesterday = utcCalendar.date(byAdding: .day, value: -1, to: now), utcCalendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday · \(dateText)" }
        return dateText
    }

    @MainActor private func load() async {
        let sats = favorites
        guard !sats.isEmpty else { entries = []; return }
        loading = true
        let observer = store.preferences.observer
        let minEl = store.preferences.minElevation
        let start = utcCalendar.startOfDay(for: Date()).addingTimeInterval(-Double(daysBack) * 86400)
        let span = Double(daysBack + daysForward + 1)
        let result = await Task.detached(priority: .userInitiated) { () -> [ScheduleEntry] in
            var out: [ScheduleEntry] = []
            // Allow enough passes to fill the whole span for even a frequently-seen
            // satellite (~20/day is generous); the old fixed 500 truncated the later
            // days once the window grew past a few weeks.
            let cap = max(500, Int(span) * 20)
            for sat in sats {
                let passes = (try? OrbitPredictor.predictPasses(sat, observer: observer, from: start,
                                                                minElevation: minEl, maxCount: cap,
                                                                horizonDays: span)) ?? []
                for p in passes {
                    out.append(ScheduleEntry(id: "\(sat.id)-\(p.aos.timeIntervalSince1970)",
                                             satelliteID: sat.id, name: sat.name, pass: p))
                }
            }
            return out
        }.value
        entries = result
        loading = false
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

struct PassesView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var passes: [PredictedPass] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var alarmMessage: String?
    @State private var detailPass: PredictedPass?
    @State private var minEl = 5

    private let minElevationPresets = [0, 5, 10, 20, 30]

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            minElevationBar
            content
        }
        .task(id: taskKey) { await load() }
        .alert("Pass alarm", isPresented: Binding(
            get: { alarmMessage != nil },
            set: { if !$0 { alarmMessage = nil } }
        )) {
            Button("OK") { alarmMessage = nil }
        } message: {
            Text(alarmMessage ?? "")
        }
        .sheet(item: $detailPass) { pass in
            if let satellite = store.selectedSatellite {
                PassDetailSheet(satellite: satellite, pass: pass, observer: store.preferences.observer)
            }
        }
    }

    private var minElevationBar: some View {
        HStack(spacing: 12) {
            Text("Min El")
                .font(.subheadline)
                .foregroundStyle(ODTheme.muted)
            Picker("Minimum elevation", selection: $minEl) {
                ForEach(minElevationPresets, id: \.self) { Text(verbatim: "\($0)°").tag($0) }
            }
            .pickerStyle(.segmented)
            // Local to this screen only: seed from the global default once, but do
            // not write it back. Changing the mask here re-filters just this list
            // (via taskKey) and leaves the app-wide minimum untouched.
            .onAppear {
                let current = Int(store.preferences.minElevation.rounded())
                minEl = minElevationPresets.min(by: { abs($0 - current) < abs($1 - current) }) ?? 5
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && passes.isEmpty {
            Spacer()
            ProgressView("Computing passes…")
            Spacer()
        } else if let errorMessage, passes.isEmpty {
            Spacer()
            ContentUnavailableView("Pass prediction failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            Spacer()
        } else if passes.isEmpty {
            Spacer()
            ContentUnavailableView(
                "No qualifying passes",
                systemImage: "moon.stars",
                description: Text("No passes above \(ODFormat.angle(Double(minEl))) were found in the next 10 days.")
            )
            Spacer()
        } else {
            List {
                Section("\(passes.count) passes · next 10 days") {
                    ForEach(Array(passes.enumerated()), id: \.element.id) { index, pass in
                        passRow(pass, isBest: index == bestPassIndex)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    private func passRow(_ pass: PredictedPass, isBest: Bool) -> some View {
        let score = quality(pass)
        return HStack(spacing: 8) {
            Button {
                detailPass = pass
            } label: {
                HStack(spacing: 12) {
                VStack(spacing: 1) {
                    Text(ODFormat.angle(pass.maxElevation, decimals: 0))
                        .font(.headline.monospacedDigit())
                    Text("MAX EL")
                        .font(.system(size: 8).weight(.semibold))
                        .foregroundStyle(ODTheme.muted)
                }
                .frame(width: 56)
                .padding(.vertical, 8)
                .background(qualityColor(score).opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(ODFormat.utcShort.string(from: pass.aos))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(ODFormat.secondaryClock(pass.aos))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ODTheme.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if isBest {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(ODTheme.warning)
                        }
                        Spacer()
                        Text(relativeAOS(pass.aos))
                            .font(.caption)
                            .foregroundStyle(ODTheme.muted)
                    }
                    HStack(spacing: 14) {
                        Label(ODFormat.duration(pass.duration), systemImage: "clock")
                        Label("\(ODFormat.compass(pass.aosAzimuth))→\(ODFormat.compass(pass.losAzimuth))", systemImage: "arrow.left.and.right")
                        Spacer()
                        Text(verbatim: "Q\(score)")
                            .foregroundStyle(qualityColor(score))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ODTheme.muted)
                }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)

            if pass.aos > Date(), let satellite = store.selectedSatellite {
                PassAlarmButton(satellite: satellite, pass: pass,
                                observer: store.preferences.observer,
                                leadMinutes: store.preferences.passAlarmLeadMinutes ?? 10)
            } else {
                PassAlarmUnavailable()   // keep rows aligned
            }
        }
        .swipeActions(edge: .trailing) {
            Button {
                Task { await scheduleAlarm(pass) }
            } label: {
                Label("Alarm", systemImage: "bell.badge")
            }
            .tint(ODTheme.accent)
        }
    }

    // MARK: - Derived values

    private var bestPassIndex: Int? {
        guard !passes.isEmpty else { return nil }
        return passes.indices.max(by: { quality(passes[$0]) < quality(passes[$1]) })
    }

    /// Simple 0–100 pass-quality score weighting peak elevation over duration.
    private func quality(_ pass: PredictedPass) -> Int {
        let elevationFactor = min(1.0, max(0, pass.maxElevation) / 90.0)
        let durationFactor = min(1.0, pass.duration / 900.0)
        return Int((0.7 * elevationFactor + 0.3 * durationFactor) * 100)
    }

    private func qualityColor(_ score: Int) -> Color {
        score >= 70 ? ODTheme.good : (score >= 40 ? ODTheme.accent : ODTheme.muted)
    }

    private func relativeAOS(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        return seconds <= 0 ? "in progress" : "in \(ODFormat.duration(seconds))"
    }

    private var taskKey: String {
        let o = store.preferences.observer
        return "\(store.selectedSatellite?.id ?? 0)-\(o.latitude)-\(o.longitude)-\(minEl)"
    }

    @MainActor
    private func scheduleAlarm(_ pass: PredictedPass) async {
        guard let satellite = store.selectedSatellite else { return }
        let lead = store.preferences.passAlarmLeadMinutes ?? 10
        do {
            try await PassAlarmService.schedule(pass: pass, satellite: satellite,
                                                observer: store.preferences.observer,
                                                leadMinutes: lead)
            alarmMessage = "Scheduled \(lead) minute(s) before \(ODFormat.utcShort.string(from: pass.aos))."
        } catch {
            alarmMessage = error.localizedDescription
        }
    }

    @MainActor
    private func load() async {
        passes = []
        errorMessage = nil
        guard let satellite = store.selectedSatellite else { return }
        isLoading = true
        defer { isLoading = false }

        let observer = store.preferences.observer
        let minimum = Double(minEl)   // local mask for this screen only
        do {
            passes = try await Task.detached(priority: .userInitiated) {
                try OrbitPredictor.predictPasses(
                    satellite,
                    observer: observer,
                    minElevation: minimum,
                    maxCount: 20
                )
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Preloaded detail for a specific pass tapped in the list: its sky-track arc
/// and the pass timings/geometry.
private struct PassDetailSheet: View {
    let satellite: SatelliteRecord
    let pass: PredictedPass
    let observer: ObserverSite
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SkyPoint] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PolarSkyPlot(points: path, minimumElevation: 0)
                        .frame(maxHeight: 460)
                        .padding()

                    SectionCard("Pass") {
                        MetricRow("Satellite", satellite.name)
                        MetricRow("AOS", ODFormat.utc.string(from: pass.aos), valueColor: ODTheme.good)
                        MetricRow("TCA", ODFormat.utc.string(from: pass.tca))
                        MetricRow("LOS", ODFormat.utc.string(from: pass.los), valueColor: ODTheme.warning)
                        MetricRow("Duration", ODFormat.duration(pass.duration))
                        MetricRow("Maximum elevation", ODFormat.angle(pass.maxElevation))
                        MetricRow("AOS azimuth", "\(ODFormat.compass(pass.aosAzimuth)) \(ODFormat.angle(pass.aosAzimuth, decimals: 0))")
                        MetricRow("LOS azimuth", "\(ODFormat.compass(pass.losAzimuth)) \(ODFormat.angle(pass.losAzimuth, decimals: 0))")
                    }
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Pass Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                path = (try? await Task.detached(priority: .userInitiated) {
                    try OrbitPredictor.skyPath(satellite, observer: observer, pass: pass)
                }.value) ?? []
            }
        }
    }
}
