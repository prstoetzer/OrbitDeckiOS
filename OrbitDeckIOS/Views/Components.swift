import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Identifiable wrapper so a prepared file URL can drive a `.sheet(item:)`.
struct ShareURLItem: Identifiable { let url: URL; var id: URL { url } }

/// Reverse-geocodes the observer position while following the current location and
/// hands the resolved DXCC entity / administrative subdivisions to a content
/// builder, so different screens (Home card, Settings form) can render the same
/// data in their own row style. Renders nothing in fixed-site mode or before the
/// lookup resolves. Re-geocodes only when the coarse position changes.
struct CurrentLocationEntityInfo<Content: View>: View {
    @EnvironmentObject private var store: OrbitStore
    @ViewBuilder let content: (GeoLocationEntity) -> Content

    var body: some View {
        // Purely reactive: the store reverse-geocodes on the location-update path
        // and publishes `currentLocationEntity`, so this renders reliably without
        // depending on a conditionally-rendered view's `.task` lifecycle.
        if store.locationMode == .currentLocation,
           let info = store.currentLocationEntity, info.hasAnything {
            content(info)
        }
    }
}

#if canImport(UIKit)
/// The system share sheet, presented programmatically (so exports open the share
/// UI directly rather than surfacing a button in an unrelated section).
struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

enum ODFormat {
    /// Operator preference: when true, all displayed times use the device's local
    /// zone instead of UTC. Driven from the store (see OrbitStore.loadPreferences).
    /// Tiny BASIC deliberately ignores this and always uses UTC.
    nonisolated(unsafe) static var useLocalTime = false

    // UTC is always 24-hour with a literal 'UTC' (the ham convention; `zzz` in the
    // GMT zone renders "GMT"). POSIX locale pins 24-hour regardless of the device.
    private static func fixedUTC(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }
    // Whether the device is set to 24-hour time. `j` resolves to the locale's
    // preferred hour field; a 12-hour locale includes the AM/PM ('a') symbol.
    private static let deviceUses24Hour: Bool = {
        let t = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        return !t.contains("a")
    }()
    // Local formatters honor the device's 12/24-hour preference and current locale
    // (AM/PM symbols), with the live zone abbreviation via `zzz`.
    private static func local(_ format24: String, _ format12: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = .current
        f.dateFormat = deviceUses24Hour ? format24 : format12
        return f
    }

    private static let utcFull = fixedUTC("yyyy-MM-dd HH:mm:ss 'UTC'")
    private static let localFull = local("yyyy-MM-dd HH:mm:ss zzz", "yyyy-MM-dd h:mm:ss a zzz")
    private static let utcShortFixed = fixedUTC("MMM d HH:mm:ss 'UTC'")
    private static let localShort = local("MMM d HH:mm:ss zzz", "MMM d h:mm:ss a zzz")
    private static let utcDayFixed = fixedUTC("yyyy-MM-dd")
    private static let localDay = local("yyyy-MM-dd", "yyyy-MM-dd")
    private static let utcClock = fixedUTC("HH:mm 'UTC'")
    private static let localClock = local("HH:mm zzz", "h:mm a zzz")

    static var utc: DateFormatter { useLocalTime ? localFull : utcFull }
    static var utcShort: DateFormatter { useLocalTime ? localShort : utcShortFixed }
    static var utcDay: DateFormatter { useLocalTime ? localDay : utcDayFixed }

    /// Short "HH:mm ZZZ" clock in the operator's chosen zone (for pass lists).
    static func primaryClock(_ date: Date) -> String {
        (useLocalTime ? localClock : utcClock).string(from: date)
    }
    /// The same clock in the *other* zone, for an unobtrusive secondary readout
    /// (e.g. show local next to UTC, or vice-versa). Empty if both would match.
    static func secondaryClock(_ date: Date) -> String {
        (useLocalTime ? utcClock : localClock).string(from: date)
    }

    static func angle(_ degrees: Double, decimals: Int = 1) -> String {
        String(format: "%.*f°", decimals, degrees)
    }

    static func distance(_ km: Double) -> String {
        km >= 10_000 ? String(format: "%.0f km", km) : String(format: "%.1f km", km)
    }

    static func velocity(_ kmS: Double) -> String {
        String(format: "%+.3f km/s", kmS)
    }

    static func frequency(_ hz: Int64) -> String {
        let value = Double(hz)
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.6f GHz", value / 1_000_000_000)
        }
        if abs(value) >= 1_000_000 {
            return String(format: "%.6f MHz", value / 1_000_000)
        }
        if abs(value) >= 1_000 {
            return String(format: "%.3f kHz", value / 1_000)
        }
        return "\(hz) Hz"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0
            ? String(format: "%dh %02dm %02ds", h, m, sec)
            : String(format: "%dm %02ds", m, sec)
    }

    static func compass(_ azimuth: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int((azimuth.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 22.5 + 0.5) % 16
        return points[index]
    }
}

struct SelectedSatelliteHeader: View {
    @EnvironmentObject private var store: OrbitStore

    var body: some View {
        HStack(spacing: 10) {
            if let satellite = store.selectedSatellite {
                Image(systemName: "dot.scope")
                    .foregroundStyle(ODTheme.accent)
                Text(satellite.name)
                    .font(.headline)
                Text(verbatim: "NORAD \(satellite.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(ODTheme.muted)
                Spacer()
                if store.preferences.favorites.contains(satellite.id) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(ODTheme.warning)
                }
            } else {
                Label("No satellite selected", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ODTheme.warning)
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(ODTheme.panel)
    }
}

struct PolarSkyPlot: View {
    var points: [SkyPoint]
    var currentPoint: SkyPoint?
    var minimumElevation: Double = 0
    /// Azimuth (degrees) that should point to the top of the plot. 0 = North up;
    /// pass the device heading for a "compass up" view.
    var orientation: Double = 0

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outerRadius = max(1, side / 2 - 20)

            for elevation in stride(from: 0.0, through: 90.0, by: 30.0) {
                let radius = outerRadius * (90 - elevation) / 90
                let rect = CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(ODTheme.grid),
                    lineWidth: elevation == 0 ? 1.5 : 1
                )
            }

            if minimumElevation > 0 && minimumElevation < 90 {
                let radius = outerRadius * (90 - minimumElevation) / 90
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(ODTheme.warning.opacity(0.65)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
            }

            var cross = Path()
            for cardinal in [0.0, 90.0, 180.0, 270.0] {
                let theta = (cardinal - orientation) * .pi / 180
                cross.move(to: center)
                cross.addLine(to: CGPoint(x: center.x + outerRadius * sin(theta), y: center.y - outerRadius * cos(theta)))
            }
            context.stroke(cross, with: .color(ODTheme.grid.opacity(0.8)), lineWidth: 1)

            // 8-point compass rose around the horizon rim.
            let labelRadius = outerRadius + 12
            let compass: [(String, Double)] = [
                ("N", 0), ("NE", 45), ("E", 90), ("SE", 135),
                ("S", 180), ("SW", 225), ("W", 270), ("NW", 315)
            ]
            for (text, azimuth) in compass {
                let theta = (azimuth - orientation) * .pi / 180
                let location = CGPoint(
                    x: center.x + labelRadius * sin(theta),
                    y: center.y - labelRadius * cos(theta)
                )
                context.draw(
                    Text(text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(text.count == 1 ? ODTheme.muted : ODTheme.muted.opacity(0.7)),
                    at: location
                )
            }

            // Numeric elevation-ring labels (0° horizon, 30°, 60°) along the vertical axis.
            for elevation in [0.0, 30.0, 60.0] {
                let radius = outerRadius * (90 - elevation) / 90
                context.draw(
                    Text(verbatim: "\(Int(elevation))°")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(ODTheme.muted.opacity(0.75)),
                    at: CGPoint(x: center.x + 12, y: center.y - radius + 7)
                )
            }

            if points.count > 1 {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let p = plotPoint(point.azimuth, point.elevation, center, outerRadius)
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(ODTheme.accent), lineWidth: 2.5)
            }

            // AOS / LOS marked with small heading arrows pointing along the track,
            // so they read as direction-of-travel and stay clear of the rim compass
            // labels.
            if points.count > 1 {
                let a0 = plotPoint(points[0].azimuth, points[0].elevation, center, outerRadius)
                let a1 = plotPoint(points[1].azimuth, points[1].elevation, center, outerRadius)
                drawHeadingArrow(&context, at: a0, angle: atan2(a1.y - a0.y, a1.x - a0.x), color: ODTheme.good, size: 6)
                let n = points.count
                let l0 = plotPoint(points[n - 2].azimuth, points[n - 2].elevation, center, outerRadius)
                let l1 = plotPoint(points[n - 1].azimuth, points[n - 1].elevation, center, outerRadius)
                drawHeadingArrow(&context, at: l1, angle: atan2(l1.y - l0.y, l1.x - l0.x), color: ODTheme.warning, size: 6)
            }

            // Live position: a small arrow pointing the satellite's direction of
            // travel (only while above the horizon).
            if let currentPoint, currentPoint.elevation >= 0 {
                let p = plotPoint(currentPoint.azimuth, currentPoint.elevation, center, outerRadius)
                let angle = headingAngle(for: currentPoint, center: center, outerRadius: outerRadius) ?? -.pi / 2
                drawHeadingArrow(&context, at: p, angle: angle, color: .white, size: 8.5)
                drawHeadingArrow(&context, at: p, angle: angle, color: ODTheme.accent, size: 6.5)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Polar sky plot")
    }

    private func plotPoint(
        _ azimuth: Double,
        _ elevation: Double,
        _ center: CGPoint,
        _ outerRadius: Double
    ) -> CGPoint {
        let theta = (azimuth - orientation) * .pi / 180
        let radius = outerRadius * max(0, min(1, (90 - elevation) / 90))
        return CGPoint(
            x: center.x + radius * sin(theta),
            y: center.y - radius * cos(theta)
        )
    }

    /// Screen-space direction of travel at `point`, from the track segment that
    /// brackets its time (falls back to the nearest segment).
    private func headingAngle(for point: SkyPoint, center: CGPoint, outerRadius: Double) -> Double? {
        guard points.count > 1 else { return nil }
        for i in 0..<(points.count - 1) where points[i].date <= point.date && point.date <= points[i + 1].date {
            let a = plotPoint(points[i].azimuth, points[i].elevation, center, outerRadius)
            let b = plotPoint(points[i + 1].azimuth, points[i + 1].elevation, center, outerRadius)
            if hypot(b.x - a.x, b.y - a.y) > 0.5 { return atan2(b.y - a.y, b.x - a.x) }
        }
        // Fallback: overall AOS→next direction.
        let a = plotPoint(points[0].azimuth, points[0].elevation, center, outerRadius)
        let b = plotPoint(points[1].azimuth, points[1].elevation, center, outerRadius)
        return hypot(b.x - a.x, b.y - a.y) > 0.5 ? atan2(b.y - a.y, b.x - a.x) : nil
    }
}

/// A small, unobtrusive bell toggle for scheduling (or cancelling) a local pass
/// reminder for one pass. Filled bell = a reminder is pending. Shows an alert only
/// on error (e.g. notifications denied, or the pass is too close). Designed to sit
/// beside a pass listing anywhere in the app.
struct PassAlarmButton: View {
    let satellite: SatelliteRecord
    let pass: PredictedPass
    let observer: ObserverSite
    let leadMinutes: Int

    @State private var scheduled = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Image(systemName: scheduled ? "bell.fill" : "bell")
                .font(.subheadline)
                .foregroundStyle(scheduled ? ODTheme.accent : ODTheme.muted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(working)
        .accessibilityLabel(scheduled ? "Cancel pass reminder" : "Set pass reminder \(leadMinutes) minutes before AOS")
        .task(id: pass.id) { scheduled = await PassAlarmService.isScheduled(pass: pass, satellite: satellite) }
        .alert("Pass alarm", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    private func toggle() async {
        working = true
        defer { working = false }
        if scheduled {
            PassAlarmService.cancel(pass: pass, satellite: satellite)
            scheduled = false
        } else {
            do {
                try await PassAlarmService.schedule(pass: pass, satellite: satellite, observer: observer, leadMinutes: leadMinutes)
                scheduled = true
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Shown in place of the pass-alarm bell when a pass is in progress or already
/// past (no reminder can be set), matching the bell's size so rows stay aligned.
struct PassAlarmUnavailable: View {
    var body: some View {
        Image(systemName: "bell.slash")
            .font(.subheadline)
            .foregroundStyle(ODTheme.muted.opacity(0.5))
            .frame(width: 30, height: 30)
            .accessibilityLabel("No reminder — pass in progress or past")
    }
}

/// Draw a small filled triangular heading arrow centered at `p`, pointing along
/// `angle` (radians, screen space). Used for AOS/LOS and live-position markers on
/// the sky plot and the 3D globe.
func drawHeadingArrow(_ context: inout GraphicsContext, at p: CGPoint, angle: Double, color: Color, size: CGFloat) {
    let dx = cos(angle), dy = sin(angle)
    let nx = -dy, ny = dx
    let tip = CGPoint(x: p.x + dx * size, y: p.y + dy * size)
    let back = CGPoint(x: p.x - dx * size * 0.7, y: p.y - dy * size * 0.7)
    let b1 = CGPoint(x: back.x + nx * size * 0.6, y: back.y + ny * size * 0.6)
    let b2 = CGPoint(x: back.x - nx * size * 0.6, y: back.y - ny * size * 0.6)
    var path = Path()
    path.move(to: tip); path.addLine(to: b1); path.addLine(to: b2); path.closeSubpath()
    context.fill(path, with: .color(color))
}

/// Compact toolbar control that shows the active satellite and opens a picker
/// so the operator can switch the active satellite from any screen.
struct SatelliteSwitcherButton: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "dot.scope")
                Text(store.selectedSatellite?.name ?? "Select satellite")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(ODTheme.muted)
            }
        }
        .tint(ODTheme.accent)
        .accessibilityLabel("Active satellite: \(store.selectedSatellite?.name ?? "none"). Tap to change.")
        .sheet(isPresented: $showingPicker) {
            SatellitePickerSheet()
                .environmentObject(store)
        }
    }
}

/// Searchable satellite chooser presented as a sheet by `SatelliteSwitcherButton`.
struct SatellitePickerSheet: View {
    @EnvironmentObject private var store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var favoritesOnly = false

    var body: some View {
        NavigationStack {
            List(results) { satellite in
                Button {
                    store.select(satellite.id)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: store.selectedSatellite?.id == satellite.id ? "scope" : "satellite")
                            .foregroundStyle(store.selectedSatellite?.id == satellite.id ? ODTheme.accent : ODTheme.muted)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(satellite.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(verbatim: "NORAD \(satellite.id)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ODTheme.muted)
                        }
                        Spacer()
                        if store.preferences.favorites.contains(satellite.id) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(ODTheme.warning)
                        }
                        if store.selectedSatellite?.id == satellite.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(ODTheme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: $searchText, prompt: "Name, NORAD, or designator")
            .navigationTitle("Active Satellite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("Favorites", isOn: $favoritesOnly)
                        .toggleStyle(.button)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Filtered by search + favorites toggle, with favorites floated to the top
    /// when no search is active.
    private var results: [SatelliteRecord] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = store.satellites.filter { satellite in
            if favoritesOnly && !store.preferences.favorites.contains(satellite.id) {
                return false
            }
            guard !needle.isEmpty else { return true }
            return satellite.name.lowercased().contains(needle)
                || String(satellite.id).contains(needle)
                || satellite.internationalDesignator.lowercased().contains(needle)
        }
        guard needle.isEmpty else { return filtered }
        return filtered.sorted { lhs, rhs in
            let lFav = store.preferences.favorites.contains(lhs.id)
            let rFav = store.preferences.favorites.contains(rhs.id)
            if lFav != rFav { return lFav }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

struct LoadingOrError: View {
    let isLoading: Bool
    let error: String?
    let emptyText: String

    var body: some View {
        if isLoading {
            ProgressView()
                .padding()
        } else if let error {
            ContentUnavailableView(
                "Unable to compute",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            ContentUnavailableView(
                emptyText,
                systemImage: "satellite",
                description: Text("Select a satellite or update the GP catalog.")
            )
        }
    }
}
