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

                    if let current = nearestToNow {
                        MapCircle(
                            center: current.coordinate,
                            radius: OrbitPredictor.footprintRadius(altitudeKm: current.altitudeKm) * 1000
                        )
                        .foregroundStyle(ODTheme.accent.opacity(0.12))
                        .stroke(ODTheme.accent.opacity(0.7), lineWidth: 1.5)

                        Annotation(store.selectedSatellite?.name ?? "Satellite", coordinate: current.coordinate) {
                            Image(systemName: "satellite.fill")
                                .font(.title2)
                                .foregroundStyle(ODTheme.warning)
                                .padding(7)
                                .background(.thinMaterial, in: Circle())
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .id(store.selectedSatellite?.id ?? 0)
                .overlay(alignment: .bottomLeading) {
                    if let current = nearestToNow {
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
    }

    private var taskKey: String {
        "\(store.selectedSatellite?.id ?? 0)-\(store.selectedSatellite?.epoch.timeIntervalSince1970 ?? 0)-\(orbitsAhead)"
    }

    private var nearestToNow: GroundTrackPoint? {
        let now = Date()
        return points.min { abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now)) }
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
