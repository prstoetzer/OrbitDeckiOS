import MapKit
import SwiftUI

private struct GroundTrackPoint: Identifiable {
    let id: Date
    let date: Date
    let coordinate: CLLocationCoordinate2D
    let altitudeKm: Double
}

struct GroundTrackView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var points: [GroundTrackPoint] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var orbitsAhead = 3
    @AppStorage("groundTrack.allFavoriteFootprints") private var showFavoriteFootprints = false

    private let orbitOptions = [1, 3, 5, 8]

    var body: some View {
        VStack(spacing: 0) {
            SelectedSatelliteHeader()

            HStack(spacing: 12) {
                Text("Orbits ahead").font(.subheadline).foregroundStyle(ODTheme.muted)
                Picker("Orbits ahead", selection: $orbitsAhead) {
                    ForEach(orbitOptions, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Toggle("All favorites' footprints", isOn: $showFavoriteFootprints)
                .font(.subheadline)
                .padding(.horizontal)
                .padding(.bottom, 6)
            if isLoading && points.isEmpty {
                Spacer()
                ProgressView("Computing ground track…")
                Spacer()
            } else if !points.isEmpty {
                // Drive the live marker/footprint from a 1 Hz TimelineView so the
                // satellite position updates every second. SwiftUI keeps the same
                // Map view and only refreshes its content each tick, so the camera
                // and gestures are preserved.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let current = livePoint(at: context.date) ?? nearestToNow
                    let heading = travelBearing(at: context.date)
                    let satColor = store.selectedSatellite.map { store.satellitePalette.color($0.id) } ?? ODTheme.accent
                    let minElevation = store.preferences.minElevation
                    let others = showFavoriteFootprints ? favoriteFootprints(at: context.date) : []
                    Map(position: $cameraPosition) {
                        // Thin outlines for the other favorites, each in its palette color.
                        ForEach(others, id: \.id) { fp in
                            MapPolygon(coordinates: fp.ring)
                                .foregroundStyle(.clear)
                                .stroke(fp.color.opacity(0.8), lineWidth: 1)
                        }

                        Marker(
                            store.preferences.observer.name,
                            coordinate: CLLocationCoordinate2D(
                                latitude: store.preferences.observer.latitude,
                                longitude: store.preferences.observer.longitude
                            )
                        )
                        .tint(ODTheme.good)

                        ForEach(Array(trackSegments.enumerated()), id: \.offset) { _, segment in
                            MapPolyline(coordinates: segment)
                                .stroke(satColor, lineWidth: 2.5)
                        }

                        if let current {
                            // Draw the footprint as an explicit geodesic boundary
                            // polygon rather than MapCircle: MapKit renders a large
                            // MapCircle as a constant-radius circle in the flat map
                            // projection, which overshoots geographically (it drew
                            // the AO-7 footprint covering stations well below the
                            // horizon). This boundary is the true 0°-elevation circle.
                            MapPolygon(coordinates: footprintBoundary(
                                center: current.coordinate, altitudeKm: current.altitudeKm))
                            .foregroundStyle(satColor.opacity(0.12))
                            .stroke(satColor.opacity(0.7), lineWidth: 1.5)

                            // Dashed ring where the satellite stands at the
                            // operator's minimum elevation: the usable footprint.
                            if minElevation > 0 {
                                MapPolygon(coordinates: footprintBoundary(
                                    center: current.coordinate, altitudeKm: current.altitudeKm,
                                    elevation: minElevation))
                                .foregroundStyle(.clear)
                                .stroke(satColor.opacity(0.9), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                            }

                            Annotation(store.selectedSatellite?.name ?? "Satellite", coordinate: current.coordinate) {
                                Image(systemName: "arrowtriangle.up.fill")
                                    .font(.callout)
                                    .foregroundStyle(ODTheme.warning)
                                    .rotationEffect(.degrees(heading))
                                    .padding(6)
                                    .background(.thinMaterial, in: Circle())
                                    .accessibilityLabel("Satellite heading \(Int(heading))°")
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat))
                    .id(store.selectedSatellite?.id ?? 0)
                    // Top-trailing keeps the readout clear of Apple Maps' bottom-leading
                    // logo and bottom-trailing legal attribution link.
                    .overlay(alignment: .topTrailing) {
                        if let current {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ODFormat.utc.string(from: current.date))
                                Text(ODFormat.units(String(format: "%.3f°, %.3f°  •  %.1f km",
                                            current.coordinate.latitude,
                                            current.coordinate.longitude,
                                            current.altitudeKm)))
                            }
                            .font(.caption.monospacedDigit())
                            .padding(10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding()
                        }
                    }
                }
            } else {
                Spacer()
                ContentUnavailableView(
                    "Ground track unavailable",
                    systemImage: "map",
                    description: Text(errorMessage ?? "Select a satellite.")
                )
                Spacer()
            }
        }
        .task(id: taskKey) { await load() }
        .onChange(of: store.preferences.selectedNorad) { _, _ in
            cameraPosition = .automatic
            Task { await load() }
        }
        .onChange(of: orbitsAhead) { _, _ in
            cameraPosition = .automatic
            Task { await load() }
        }
    }

    private var taskKey: String {
        "\(store.selectedSatellite?.id ?? 0)-\(store.selectedSatellite?.epoch.timeIntervalSince1970 ?? 0)"
    }

    private var nearestToNow: GroundTrackPoint? {
        let now = Date()
        return points.min { abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now)) }
    }

    /// The satellite's exact sub-point at `date` (recomputed live each tick), so
    /// the marker/footprint sit on the true position rather than the nearest
    /// precomputed track sample.
    private func livePoint(at date: Date) -> GroundTrackPoint? {
        guard let sat = store.selectedSatellite,
              let look = try? OrbitPredictor.look(sat, observer: store.preferences.observer, at: date) else { return nil }
        return GroundTrackPoint(
            id: date, date: date,
            coordinate: CLLocationCoordinate2D(latitude: look.subLatitude, longitude: look.subLongitude),
            altitudeKm: look.altitudeKm
        )
    }

    /// Compass bearing (0° = north) of the satellite's ground-track motion.
    /// Delegates to `OrbitPredictor.groundBearing`, which uses a period-adaptive
    /// central difference so the arrow stays correct at HEO apogee (a fixed 20 s
    /// forward step there spans sub-degree motion) and across the antimeridian.
    private func travelBearing(at date: Date) -> Double {
        guard let sat = store.selectedSatellite,
              let bearing = OrbitPredictor.groundBearing(sat, observer: store.preferences.observer, at: date) else { return 0 }
        return bearing
    }

    /// The true footprint boundary for `elevation` (0° = the horizon footprint):
    /// the ring of points at the Earth-central angle `FootprintGeometry.centralAngle`
    /// from the sub-point, walked by bearing. Geodesically exact, unlike a
    /// projected MapCircle.
    private func footprintBoundary(center: CLLocationCoordinate2D, altitudeKm: Double,
                                   elevation: Double = 0) -> [CLLocationCoordinate2D] {
        let angle = FootprintGeometry.centralAngle(altitudeKm: altitudeKm, elevation: elevation)
        return FootprintGeometry.ring(latitude: center.latitude, longitude: center.longitude, angleDeg: angle)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// Horizon footprints of every favorite except the selected one, at `date`.
    private func favoriteFootprints(at date: Date) -> [(id: UInt, color: Color, ring: [CLLocationCoordinate2D])] {
        let palette = store.satellitePalette
        return store.satellites
            .filter { store.preferences.favorites.contains($0.id) && $0.id != store.selectedSatellite?.id }
            .prefix(40)
            .compactMap { sat in
                guard let sub = try? OrbitPredictor.subpoint(sat, at: date) else { return nil }
                let ring = footprintBoundary(center: CLLocationCoordinate2D(latitude: sub.latitude, longitude: sub.longitude),
                                             altitudeKm: sub.altitudeKm)
                return (sat.id, palette.color(sat.id), ring)
            }
    }

    private var trackSegments: [[CLLocationCoordinate2D]] {
        guard !points.isEmpty else { return [] }
        var result: [[CLLocationCoordinate2D]] = [[]]
        var previous: CLLocationCoordinate2D?

        for point in points {
            if let previous, abs(point.coordinate.longitude - previous.longitude) > 180 {
                result.append([])
            }
            result[result.count - 1].append(point.coordinate)
            previous = point.coordinate
        }
        return result.filter { $0.count >= 2 }
    }

    @MainActor
    private func load() async {
        points = []
        errorMessage = nil
        guard let satellite = store.selectedSatellite else { return }
        isLoading = true
        defer { isLoading = false }

        // Forward-only: span [now, now + orbitsAhead orbits] by centering the
        // window half a span into the future.
        let duration = Double(orbitsAhead) * max(1, satellite.periodMinutes)
        let center = Date().addingTimeInterval(duration * 30)
        do {
            let raw = try await Task.detached(priority: .userInitiated) {
                try OrbitPredictor.groundTrack(satellite, centeredAt: center, durationMinutes: duration)
            }.value
            points = raw.map {
                GroundTrackPoint(
                    id: $0.0,
                    date: $0.0,
                    coordinate: CLLocationCoordinate2D(latitude: $0.1, longitude: $0.2),
                    altitudeKm: $0.3
                )
            }
            // Recenter on the new satellite's current sub-point. Setting
            // `.automatic` again does not re-fit when it's already automatic, so
            // switching satellites would appear not to update the map.
            if let current = points.min(by: { abs($0.date.timeIntervalSinceNow) < abs($1.date.timeIntervalSinceNow) }) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: current.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 90, longitudeDelta: 120)
                ))
            } else {
                cameraPosition = .automatic
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
