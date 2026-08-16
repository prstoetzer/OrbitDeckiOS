import SwiftUI
import UniformTypeIdentifiers

private enum SatMode: String, CaseIterable, Identifiable {
    case catalog = "Catalog"
    case visible = "Visible now"
    case byType = "By type"
    var id: String { rawValue }
}

private struct VisibleSat: Identifiable, Sendable {
    let satellite: SatelliteRecord
    let elevation: Double
    let azimuth: Double
    var id: UInt { satellite.id }
}

struct SatellitesView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var searchText = ""
    @State private var favoritesOnly = false
    @State private var showingImporter = false
    @State private var showingManualEditor = false
    @State private var manualEditorRecord: SatelliteRecord?
    @State private var showingTransponderManager = false
    @State private var showingOnlineSearch = false
    @State private var mode: SatMode = .catalog
    @State private var visibleNow: [VisibleSat] = []
    @State private var visibleScanning = false
    @State private var visibleScannedAt: Date?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Favorites", isOn: $favoritesOnly)
                    .toggleStyle(.button)

                Spacer()

                Menu {
                    Button {
                        showingOnlineSearch = true
                    } label: {
                        Label("Search CelesTrak Online", systemImage: "magnifyingglass.circle")
                    }
                    Button {
                        manualEditorRecord = nil
                        showingManualEditor = true
                    } label: {
                        Label("Add Manual Satellite", systemImage: "plus.circle")
                    }
                    Button {
                        showingTransponderManager = true
                    } label: {
                        Label("Manual Transponders", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(store.selectedSatellite == nil)
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import Elements (OMM / TLE)", systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button {
                        Task { await store.refreshAllTransponders() }
                    } label: {
                        Label("Cache all transponders (SatNOGS)", systemImage: "square.and.arrow.down.on.square")
                    }
                    .disabled(store.isRefreshingTransponders)
                } label: {
                    Label("Add", systemImage: "plus")
                }

                Button {
                    Task { await store.refreshGP() }
                } label: {
                    if store.isRefreshingGP {
                        ProgressView()
                    } else {
                        Label("Update GP", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(store.isRefreshingGP)
            }
            .padding()

            if let age = store.catalogAgeDays {
                HStack {
                    Text("\(store.satellites.count) objects")
                    Text("•")
                    Text(String(format: "freshest elements %.2f days old", age))
                    Spacer()
                    Text(store.statusMessage)
                }
                .font(.caption)
                .foregroundStyle(age > 14 ? ODTheme.warning : ODTheme.muted)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Picker("Mode", selection: $mode) {
                ForEach(SatMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)

            modeContent
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name, NORAD, or designator")
                .task(id: visibleScanKey) { if mode == .visible { await scanVisible() } }
        }
        .sheet(isPresented: $showingOnlineSearch) {
            CelesTrakSearchSheet()
                .environmentObject(store)
        }
        .sheet(isPresented: $showingManualEditor) {
            ManualSatelliteEditor(record: manualEditorRecord)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingTransponderManager) {
            if let sat = store.selectedSatellite {
                ManualTransponderManager(satellite: sat)
                    .environmentObject(store)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.plainText, .text, .json, .xml, .commaSeparatedText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    store.importTLEText(text)
                } catch {
                    store.lastError = "Could not read the elements file: \(error.localizedDescription)"
                }
            case .failure(let error):
                store.lastError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var modeContent: some View {
        switch mode {
        case .catalog:
            List(filteredSatellites) { catalogRow($0) }
                .listStyle(.plain)
        case .visible:
            List {
                Section {
                    ForEach(filteredVisible) { visibleRow($0) }
                    if filteredVisible.isEmpty && !visibleScanning {
                        Text("No catalog satellites are above the horizon right now.")
                            .foregroundStyle(ODTheme.muted)
                    }
                } header: {
                    if visibleScanning {
                        Label("Scanning \(store.satellites.count) objects…", systemImage: "clock")
                    } else {
                        Text("\(visibleNow.count) above horizon\(visibleScannedAt.map { " · \(ODFormat.utcShort.string(from: $0))" } ?? "")")
                    }
                }
            }
            .listStyle(.plain)
        case .byType:
            List {
                ForEach(typeGroups, id: \.name) { group in
                    Section("\(group.name) (\(group.satellites.count))") {
                        ForEach(group.satellites) { catalogRow($0) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder private func catalogRow(_ satellite: SatelliteRecord) -> some View {
        Button {
            store.select(satellite.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: store.selectedSatellite?.id == satellite.id ? "scope" : "satellite")
                    .foregroundStyle(store.selectedSatellite?.id == satellite.id ? ODTheme.accent : ODTheme.muted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(satellite.name)
                            .foregroundStyle(.primary)
                        if satellite.isManual {
                            Text("MANUAL")
                                .font(.caption2.bold())
                                .foregroundStyle(ODTheme.warning)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: "NORAD \(satellite.id)")
                        if !satellite.internationalDesignator.isEmpty {
                            Text(satellite.internationalDesignator)
                        }
                        Text(String(format: "%.1f min", satellite.periodMinutes))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(ODTheme.muted)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(String(format: "%.1f°", satellite.inclinationDeg))
                        .font(.caption.monospacedDigit())
                    Text(String(format: "%.0f–%.0f km", satellite.perigeeKm, satellite.apogeeKm))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ODTheme.muted)
                }

                Button {
                    store.toggleFavorite(satellite.id)
                } label: {
                    Image(systemName: store.preferences.favorites.contains(satellite.id) ? "star.fill" : "star")
                        .foregroundStyle(store.preferences.favorites.contains(satellite.id) ? ODTheme.warning : ODTheme.muted)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(store.preferences.favorites.contains(satellite.id) ? "Remove favorite" : "Add favorite")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if satellite.isManual {
                Button {
                    manualEditorRecord = satellite
                    showingManualEditor = true
                } label: {
                    Label("Edit Manual Satellite", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.deleteManualSatellite(satellite.id)
                } label: {
                    Label("Delete Manual Satellite", systemImage: "trash")
                }
            }
            Button {
                store.select(satellite.id)
                showingTransponderManager = true
            } label: {
                Label("Manual Transponders", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    @ViewBuilder private func visibleRow(_ entry: VisibleSat) -> some View {
        Button {
            store.select(entry.satellite.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: store.selectedSatellite?.id == entry.satellite.id ? "scope" : "satellite")
                    .foregroundStyle(store.selectedSatellite?.id == entry.satellite.id ? ODTheme.accent : ODTheme.good)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.satellite.name).foregroundStyle(.primary)
                    Text(verbatim: "NORAD \(entry.satellite.id)")
                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("el \(ODFormat.angle(entry.elevation))")
                        .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.good)
                    Text("az \(ODFormat.angle(entry.azimuth, decimals: 0)) \(ODFormat.compass(entry.azimuth))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(ODTheme.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredVisible: [VisibleSat] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return visibleNow }
        return visibleNow.filter {
            $0.satellite.name.lowercased().contains(needle) || String($0.satellite.id).contains(needle)
        }
    }

    private var typeGroups: [(name: String, satellites: [SatelliteRecord])] {
        let grouped = Dictionary(grouping: filteredSatellites) { $0.transponders.first?.kind ?? "No transponder" }
        return grouped
            .map { (name: $0.key, satellites: $0.value) }
            .sorted { $0.satellites.count > $1.satellites.count }
    }

    private var visibleScanKey: String {
        let o = store.preferences.observer
        return "\(mode.rawValue)-\(o.latitude)-\(o.longitude)-\(store.satellites.count)"
    }

    @MainActor
    private func scanVisible() async {
        let satellites = store.satellites
        let observer = store.preferences.observer
        guard !satellites.isEmpty else { visibleNow = []; return }
        visibleScanning = true
        let now = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> [VisibleSat] in
            var output: [VisibleSat] = []
            for satellite in satellites {
                if let look = try? OrbitPredictor.look(satellite, observer: observer, at: now), look.elevation >= 0 {
                    output.append(VisibleSat(satellite: satellite, elevation: look.elevation, azimuth: look.azimuth))
                }
            }
            return output.sorted { $0.elevation > $1.elevation }
        }.value
        if Task.isCancelled { return }
        visibleScanning = false
        visibleScannedAt = now
        visibleNow = result
    }

    private var filteredSatellites: [SatelliteRecord] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.satellites.filter { satellite in
            if favoritesOnly && !store.preferences.favorites.contains(satellite.id) {
                return false
            }
            guard !needle.isEmpty else { return true }
            return satellite.name.lowercased().contains(needle)
                || String(satellite.id).contains(needle)
                || satellite.internationalDesignator.lowercased().contains(needle)
        }
    }
}

/// Searches CelesTrak's live catalog by name or NORAD ID and adds results to the
/// user's satellites (they then stay on the normal GP refresh path).
struct CelesTrakSearchSheet: View {
    @EnvironmentObject private var store: OrbitStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SatelliteRecord] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var addedIDs: Set<UInt> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Search CelesTrak's live catalog by satellite name or NORAD ID, then add a result to your satellites. Added objects are refreshed on the normal GP-update path.")
                        .font(.caption)
                        .foregroundStyle(ODTheme.muted)
                }
                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                if let message {
                    Text(message).foregroundStyle(ODTheme.warning)
                }
                if !results.isEmpty {
                    Section("\(results.count) result(s)") {
                        ForEach(results) { record in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.name)
                                    Text(verbatim: "NORAD \(record.id)\(record.internationalDesignator.isEmpty ? "" : " · \(record.internationalDesignator)")")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(ODTheme.muted)
                                }
                                Spacer()
                                if store.satellites.contains(where: { $0.id == record.id }) || addedIDs.contains(record.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ODTheme.good)
                                } else {
                                    Button("Add") { add(record) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Name or NORAD ID")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .navigationTitle("Search CelesTrak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @MainActor
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        message = nil
        results = []
        defer { isSearching = false }
        do {
            let found = try await ActivationService.searchCelesTrak(trimmed)
            results = found
            if found.isEmpty { message = "No matching objects found in CelesTrak." }
        } catch {
            message = error.localizedDescription
        }
    }

    private func add(_ record: SatelliteRecord) {
        store.addExtraSatellite(record, transponders: record.transponders)
        addedIDs.insert(record.id)
        Task { await store.loadTransponders(for: record.id) }
    }
}
