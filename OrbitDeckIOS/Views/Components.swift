import SwiftUI

enum ODFormat {
    nonisolated(unsafe) static let utc: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return f
    }()

    nonisolated(unsafe) static let utcShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "MMM d HH:mm:ss 'UTC'"
        return f
    }()

    nonisolated(unsafe) static let utcDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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

            if let first = points.first {
                let p = plotPoint(first.azimuth, first.elevation, center, outerRadius)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                             with: .color(ODTheme.good))
            }
            if let last = points.last, points.count > 1 {
                let p = plotPoint(last.azimuth, last.elevation, center, outerRadius)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                             with: .color(ODTheme.warning))
            }

            // Only mark the live position when the satellite is actually above
            // the horizon; below-horizon positions have no place on a sky plot.
            if let currentPoint, currentPoint.elevation >= 0 {
                let p = plotPoint(currentPoint.azimuth, currentPoint.elevation, center, outerRadius)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                             with: .color(ODTheme.accent))
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(.white.opacity(0.85)), lineWidth: 1)
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
