import SwiftUI

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
        return Button {
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
        .buttonStyle(.plain)
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
