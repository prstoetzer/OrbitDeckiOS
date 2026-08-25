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
                    Map(position: $cameraPosition) {
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
                                .stroke(ODTheme.accent, lineWidth: 2.5)
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
                            .foregroundStyle(ODTheme.accent.opacity(0.12))
                            .stroke(ODTheme.accent.opacity(0.7), lineWidth: 1.5)

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
                                Text(String(format: "%.3f°, %.3f°  •  %.1f km",
                                            current.coordinate.latitude,
                                            current.coordinate.longitude,
                                            current.altitudeKm))
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

    /// Compass bearing (0° = north) of the satellite's ground-track motion, from
    /// its sub-point now vs ~20 s ahead. Drives the heading arrow marker.
    private func travelBearing(at date: Date) -> Double {
        guard let a = livePoint(at: date),
              let b = livePoint(at: date.addingTimeInterval(20)) else { return 0 }
        let lat1 = a.coordinate.latitude * .pi / 180, lat2 = b.coordinate.latitude * .pi / 180
        let dLon = (b.coordinate.longitude - a.coordinate.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var bearing = atan2(y, x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    /// The true 0°-elevation footprint boundary: the ring of points at the
    /// Earth-central angle acos(Re/(Re+h)) from the sub-point, walked by bearing.
    /// Geodesically exact, unlike a projected MapCircle.
    private func footprintBoundary(center: CLLocationCoordinate2D, altitudeKm: Double, samples: Int = 180) -> [CLLocationCoordinate2D] {
        let re = 6371.0
        let gamma = acos(max(-1, min(1, re / (re + max(0, altitudeKm)))))
        let lat0 = center.latitude * .pi / 180, lon0 = center.longitude * .pi / 180
        let sinLat0 = sin(lat0), cosLat0 = cos(lat0), sinG = sin(gamma), cosG = cos(gamma)
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(samples + 1)
        for i in 0...samples {
            let theta = Double(i) / Double(samples) * 2 * .pi
            let lat = asin(sinLat0 * cosG + cosLat0 * sinG * cos(theta))
            let lon = lon0 + atan2(sin(theta) * sinG * cosLat0, cosG - sinLat0 * sin(lat))
            var lonDeg = lon * 180 / .pi
            while lonDeg > 180 { lonDeg -= 360 }
            while lonDeg < -180 { lonDeg += 360 }
            coords.append(CLLocationCoordinate2D(latitude: lat * 180 / .pi, longitude: lonDeg))
        }
        return coords
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
