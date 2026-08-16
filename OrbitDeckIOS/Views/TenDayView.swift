import SwiftUI

/// Multi-day pass progression for the selected satellite: one row per UTC day
/// with a 24-hour timeline where each pass is drawn at its time-of-day, its
/// width = duration, shaded by maximum elevation. Mirrors the desktop screen.
struct TenDayView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var passes: [PredictedPass] = []
    @State private var days = 10
    @State private var isLoading = false
    @State private var errorMessage: String?
    // Passes are accumulated incrementally: `baseNow` anchors lane 0 and the
    // prediction window, and `computedDays` records how far ahead we've already
    // predicted so "Load 7 more days" only computes the new slice and appends.
    @State private var baseNow = Date()
    @State private var computedDays = 0

    private static let utc = TimeZone(identifier: "UTC")!
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = "EEE"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = utc; f.dateFormat = "MM-dd"; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()
            content
        }
        .task(id: baseKey) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && passes.isEmpty {
            Spacer(); ProgressView("Computing pass progression…"); Spacer()
        } else if let errorMessage, passes.isEmpty {
            Spacer()
            ContentUnavailableView("Pass progression unavailable", systemImage: "chart.bar.xaxis", description: Text(errorMessage))
            Spacer()
        } else if passes.isEmpty {
            Spacer()
            ContentUnavailableView("No passes", systemImage: "chart.bar.xaxis",
                description: Text("No passes were found in the next \(days) days."))
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text("\(passes.count) passes over \(days) days")
                        .font(.caption).foregroundStyle(ODTheme.muted)
                        .padding(.horizontal)
                        .padding(.top, 4)

                    ForEach(Array(0..<days), id: \.self) { offset in
                        dayLane(offset: offset)
                    }

                    Button {
                        days += 7
                        Task { await extend() }
                    } label: {
                        HStack {
                            if isLoading { ProgressView() }
                            Label("Load 7 more days", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoading)
                    .padding()
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func dayLane(offset: Int) -> some View {
        let start = dayStart(offset: offset)
        let end = start.addingTimeInterval(86400)
        let dayPasses = passes.filter { $0.aos >= start && $0.aos < end }
        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.weekdayFormatter.string(from: start)).font(.subheadline.bold())
                Text(Self.dayFormatter.string(from: start)).font(.caption).foregroundStyle(ODTheme.muted)
                Text("\(dayPasses.count) pass\(dayPasses.count == 1 ? "" : "es")").font(.caption2).foregroundStyle(ODTheme.muted)
            }
            .frame(width: 62, alignment: .leading)

            DayTimeline(dayStart: start, passes: dayPasses)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func dayStart(offset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        let base = cal.startOfDay(for: baseNow)
        return cal.date(byAdding: .day, value: offset, to: base) ?? base
    }

    // Excludes `days`: changing the satellite or station triggers a full reload;
    // extending the horizon does not. Pass Progression shows every pass (no
    // minimum-elevation filter).
    private var baseKey: String {
        let o = store.preferences.observer
        return "\(store.selectedSatellite?.id ?? 0)-\(o.latitude)-\(o.longitude)"
    }

    @MainActor
    private func reload() async {
        passes = []
        computedDays = 0
        errorMessage = nil
        baseNow = Date()
        await extend()
    }

    /// Predicts the still-uncomputed slice [baseNow + computedDays, baseNow + days]
    /// and appends it, so the window only ever grows forward.
    @MainActor
    private func extend() async {
        guard let satellite = store.selectedSatellite else { return }
        guard days > computedDays else { return }
        let observer = store.preferences.observer
        let start = baseNow.addingTimeInterval(Double(computedDays) * 86400)
        let addDays = Double(days - computedDays)
        isLoading = true
        defer { isLoading = false }
        do {
            let more = try await Task.detached(priority: .userInitiated) {
                try OrbitPredictor.predictPasses(
                    satellite,
                    observer: observer,
                    from: start,
                    minElevation: 0,
                    maxCount: 500,
                    horizonDays: addDays
                )
            }.value
            passes.append(contentsOf: more)
            computedDays = days
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A 24-hour UTC timeline lane: hour gridlines + one bar per pass positioned by
/// time-of-day, width proportional to duration, colored by peak elevation.
private struct DayTimeline: View {
    let dayStart: Date
    let passes: [PredictedPass]

    var body: some View {
        Canvas { context, size in
            let pad: CGFloat = 6
            let usable = size.width - 2 * pad
            let top: CGFloat = 4
            let barBottom = size.height - 16

            // Hour gridlines + labels every 3 hours.
            for hour in stride(from: 0, through: 24, by: 3) {
                let x = pad + usable * CGFloat(hour) / 24.0
                var line = Path()
                line.move(to: CGPoint(x: x, y: top))
                line.addLine(to: CGPoint(x: x, y: barBottom))
                context.stroke(line, with: .color(ODTheme.grid), lineWidth: 0.7)
                if hour < 24 {
                    context.draw(
                        Text(verbatim: String(format: "%02d", hour)).font(.system(size: 7)).foregroundStyle(ODTheme.muted),
                        at: CGPoint(x: x + 8, y: size.height - 6)
                    )
                }
            }

            let dayStartTS = dayStart.timeIntervalSince1970
            for pass in passes {
                let a = max(0.0, (pass.aos.timeIntervalSince1970 - dayStartTS) / 86400.0)
                let b = min(1.0, (pass.los.timeIntervalSince1970 - dayStartTS) / 86400.0)
                let x0 = pad + usable * CGFloat(a)
                var x1 = pad + usable * CGFloat(b)
                if x1 - x0 < 3 { x1 = x0 + 3 }
                let rect = CGRect(x: x0, y: top + 2, width: x1 - x0, height: barBottom - top - 4)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(elevationColor(pass.maxElevation)))
                if x1 - x0 > 26 {
                    context.draw(
                        Text(verbatim: String(format: "%.0f°", pass.maxElevation))
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(ODTheme.background),
                        at: CGPoint(x: (x0 + x1) / 2, y: (top + barBottom) / 2)
                    )
                }
            }
        }
        .background(ODTheme.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private func elevationColor(_ elevation: Double) -> Color {
        if elevation >= 45 { return ODTheme.good }
        if elevation >= 20 { return ODTheme.accent }
        return ODTheme.passElevationMid
    }
}
