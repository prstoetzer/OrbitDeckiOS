import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Security)
import Security
#endif
#if canImport(ActivityKit)
import ActivityKit
import UIKit
#endif

@MainActor
final class OrbitStore: ObservableObject {
    @Published var satellites: [SatelliteRecord] = []
    @Published var preferences = StorePreferences() {
        didSet {
            savePreferences()
            ODFormat.useLocalTime = preferences.useLocalTime ?? false
            ODFormat.unitSystem = preferences.unitSystem ?? .system
        }
    }
    @Published var isRefreshingGP = false
    @Published var isRefreshingTransponders = false
    @Published var statusMessage = ""
    @Published var lastError: String?
    @Published var lastGPRefresh: Date?
    @Published var spaceWeather: SpaceWeatherSnapshot?
    /// Reverse-geocoded DXCC entity and administrative subdivisions for the current
    /// position, populated only while following the device location. Driven from the
    /// location-update path (not a view `.task`) so it renders reliably.
    @Published var currentLocationEntity: GeoLocationEntity?
    /// The ~1 km-rounded position last submitted for reverse geocoding, so we only
    /// re-geocode when the operator actually moves to a new locale.
    private var lastGeocodeKey: String?

    /// Full SatNOGS transmitter database keyed by NORAD id (as String), cached to
    /// disk so every catalog satellite shows its transmitters offline.
    private var allTransponders: [String: [TransponderRecord]] = [:]

    private let defaults = UserDefaults.standard
    private let prefsKey = "OrbitDeckIOS.preferences.v1"
    /// CelesTrak asks clients not to re-request the same data more than once every
    /// two hours (their GP updates no faster than that); exceeding it risks an IP
    /// ban. Timestamps are per-dataset and persisted so the limit is honored
    /// across app launches. Keys: "gp" (chosen group) and "newlaunch" (last-30-days).
    static let celestrakMinInterval: TimeInterval = 2 * 3600

    private func celestrakLastFetch(_ key: String) -> Date? {
        let t = defaults.double(forKey: "OrbitDeckIOS.celestrak.\(key)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func recordCelestrakFetch(_ key: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: "OrbitDeckIOS.celestrak.\(key)")
    }
    /// True when enough time has elapsed to politely query the given CelesTrak dataset.
    func celestrakAllowed(_ key: String = "gp") -> Bool {
        guard let last = celestrakLastFetch(key) else { return true }
        return Date().timeIntervalSince(last) >= Self.celestrakMinInterval
    }
    /// Whole minutes until the next request for the given dataset is allowed.
    func celestrakCooldownMinutes(_ key: String = "gp") -> Int {
        guard let last = celestrakLastFetch(key) else { return 0 }
        return max(0, Int(ceil((Self.celestrakMinInterval - Date().timeIntervalSince(last)) / 60)))
    }

    /// GP and the SatNOGS transmitter DB are refreshed on at least a weekly cadence.
    static let weeklyRefreshInterval: TimeInterval = 7 * 86400
    private var lastTransponderRefresh: Date? {
        get { let t = defaults.double(forKey: "OrbitDeckIOS.transponders.lastFetch"); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "OrbitDeckIOS.transponders.lastFetch") }
    }

    var selectedSatellite: SatelliteRecord? {
        guard let id = preferences.selectedNorad else { return satellites.first }
        return satellites.first(where: { $0.id == id }) ?? satellites.first
    }

    var catalogAgeDays: Double? {
        guard let newest = satellites.map(\.epoch).max() else { return nil }
        return Date().timeIntervalSince(newest) / 86400
    }

    init() {
        loadPreferences()
        seedDemoIfRequested()
    }

    /// App Store screenshot automation: with `-odDemo 1` on the launch command, seed a set
    /// of well-known amateur satellites as favorites and select one, so the data-driven
    /// screens (Track, Passes, Schedule, Ground Track) render with content. No-op otherwise,
    /// so normal launches and real installs are untouched.
    private func seedDemoIfRequested() {
        guard UserDefaults.standard.bool(forKey: "odDemo") else { return }
        // ISS, SO-50, AO-91, RS-44, AO-73, IO-117 (GreenCube).
        let demo: [UInt] = [25544, 27607, 43017, 44909, 39444, 53106]
        preferences.favorites = Set(demo)
        if preferences.selectedNorad == nil || !demo.contains(preferences.selectedNorad!) {
            preferences.selectedNorad = 25544   // ISS
        }
        savePreferences()
    }

    func bootstrap() async {
        if let data = try? Data(contentsOf: Self.transpondersCacheURL),
           let cached = try? JSONDecoder().decode([String: [TransponderRecord]].self, from: data) {
            allTransponders = cached
        }

        if let weatherData = try? Data(contentsOf: Self.spaceWeatherCacheURL),
           let cachedWeather = try? JSONDecoder().decode(SpaceWeatherSnapshot.self, from: weatherData) {
            spaceWeather = cachedWeather
        }

        if let cached = try? Data(contentsOf: Self.gpCacheURL),
           let records = try? GPService.parse(data: cached),
           !records.isEmpty {
            satellites = mergeLocalCatalog(records)
            normalizeSelection()
            statusMessage = "Loaded cached GP catalog (\(records.count) objects)"
        }

        if satellites.isEmpty || (catalogAgeDays ?? .infinity) > 1.0 {
            await refreshGP()
        }
        await refreshAllTranspondersIfNeeded()
        await refreshSpaceWeatherIfNeeded()
    }

    /// Auto-refresh the catalogs on at least a weekly cadence: GP when the loaded
    /// elements are more than a day old (also covering the weekly floor), and the
    /// SatNOGS transmitter database once per week.
    func refreshCatalogsIfNeeded() async {
        if satellites.isEmpty || (catalogAgeDays ?? .infinity) > 1.0 { await refreshGP() }
        await refreshAllTranspondersIfNeeded()
    }

    /// Refresh the SatNOGS transmitter DB if it has never been cached or is more
    /// than a week old.
    func refreshAllTranspondersIfNeeded() async {
        if !allTransponders.isEmpty, let last = lastTransponderRefresh,
           Date().timeIntervalSince(last) < Self.weeklyRefreshInterval { return }
        await refreshAllTransponders()
    }

    func select(_ norad: UInt) {
        preferences.selectedNorad = norad
        savePreferences()
    }

    func toggleFavorite(_ norad: UInt) {
        if preferences.favorites.contains(norad) {
            preferences.favorites.remove(norad)
        } else {
            preferences.favorites.insert(norad)
        }
        savePreferences()
    }

    func updateObserver(_ observer: ObserverSite) {
        preferences.observer = observer
        savePreferences()
    }

    /// True for errors that just mean "the network isn't reachable" (airplane mode,
    /// no Wi-Fi/cellular, DNS/host unreachable, timeouts). These are expected when the
    /// operator is offline and must NOT raise the app-level alert — OrbitDeck runs fully
    /// on cached elements offline, so we surface a quiet inline status instead.
    nonisolated static func isOffline(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    func refreshGP() async {
        guard !isRefreshingGP else { return }
        isRefreshingGP = true
        lastError = nil
        statusMessage = "Updating GP data…"
        defer { isRefreshingGP = false }

        let usingCelestrak = preferences.sourceKind == .celestrak
        // Extras under a SatNOGS placeholder number refresh from SatNOGS (CelesTrak
        // has never heard of those numbers); the rest go to CelesTrak by NORAD.
        let extraDefinitions = preferences.extraSatellites ?? []
        let extraIDs = extraDefinitions.filter { $0.placeholderNorad != true }.map(\.norad)
        let placeholderExtras = extraDefinitions.filter { $0.placeholderNorad == true && $0.satnogsID != nil }
        // fetchExtraNorads always queries CelesTrak (individual CATNR lookups).
        let allowedAtStart = celestrakAllowed("gp")

        // Honor CelesTrak's ≤1-request-per-2-hours policy when it is the source.
        if usingCelestrak && !allowedAtStart && !satellites.isEmpty {
            statusMessage = "Using cached elements — CelesTrak permits one update every 2 hours (try again in ~\(celestrakCooldownMinutes("gp")) min)."
            return
        }

        do {
            let result = try await GPService.fetch(preferences: preferences)
            if usingCelestrak { recordCelestrakFetch("gp") }

            var refreshedExtras: [SatelliteRecord] = []
            if !extraIDs.isEmpty && allowedAtStart {
                refreshedExtras = await GPService.fetchExtraNorads(extraIDs)
                recordCelestrakFetch("gp")
            }
            refreshedExtras += await GPService.fetchSatNOGSExtras(placeholderExtras)
            if !refreshedExtras.isEmpty {
                var byID = Dictionary(extraDefinitions.map { ($0.norad, $0) }, uniquingKeysWith: { a, _ in a })
                for index in refreshedExtras.indices {
                    let id = refreshedExtras[index].id
                    var definition = ManualSatelliteDefinition(record: refreshedExtras[index])
                    if let old = byID[id] {
                        // Keep the SatNOGS link, and its amateur name, which beats
                        // CelesTrak's interim "OBJECT A" designations.
                        definition.satnogsID = old.satnogsID
                        definition.placeholderNorad = old.placeholderNorad
                        if old.satnogsID != nil {
                            definition.name = old.name
                            refreshedExtras[index].name = old.name
                        }
                    }
                    byID[id] = definition
                }
                preferences.extraSatellites = byID.values.sorted { $0.norad < $1.norad }
            }
            let downloaded = result.records + refreshedExtras
            satellites = mergeLocalCatalog(mergeTransponders(old: satellites, new: downloaded))
            try Self.ensureApplicationSupport()
            try result.rawData.write(to: Self.gpCacheURL, options: [.atomic])
            lastGPRefresh = .now
            normalizeSelection()
            statusMessage = "GP updated: \(satellites.count) objects"
        } catch {
            // A CelesTrak 403/429 means we're being rate-limited; back off a full
            // window so we never escalate toward an IP ban.
            if usingCelestrak, case GPServiceError.badResponse(let code) = error, code == 403 || code == 429 {
                recordCelestrakFetch("gp")
                lastError = "CelesTrak rate limit reached (HTTP \(code)). OrbitDeck will wait 2 hours before querying again to avoid an IP ban; cached elements remain in use."
                statusMessage = "GP update failed"
            } else if Self.isOffline(error) {
                // Offline: keep running on cached elements, no popup.
                statusMessage = satellites.isEmpty ? "Offline — connect to download elements" : "Offline — using cached elements"
            } else {
                lastError = error.localizedDescription
                statusMessage = "GP update failed"
            }
        }
    }

    /// Fetch the entire SatNOGS transmitter database once, cache it to disk, and
    /// apply it to every loaded satellite so transponders are available offline.
    func refreshAllTransponders() async {
        guard !isRefreshingTransponders else { return }
        isRefreshingTransponders = true
        statusMessage = "Fetching SatNOGS transmitter database…"
        lastError = nil
        defer { isRefreshingTransponders = false }
        do {
            let fetched = try await TransponderService.fetchIndex()
            var byString: [String: [TransponderRecord]] = [:]
            for (norad, list) in fetched.byNorad { byString[String(norad)] = list }
            // Also cache by SatNOGS sat_id, for new-launch extras whose real
            // (six-digit) NORAD number SatNOGS can't yet record.
            for (satID, list) in fetched.bySatID { byString[Self.satnogsKey(satID)] = list }
            allTransponders = byString
            try? Self.ensureApplicationSupport()
            if let data = try? JSONEncoder().encode(byString) {
                try? data.write(to: Self.transpondersCacheURL, options: [.atomic])
            }
            satellites = satellites.map { applyManualTransponders(to: $0) }
            lastTransponderRefresh = .now
            statusMessage = "Cached transmitters for \(fetched.byNorad.count) satellites"
        } catch {
            if Self.isOffline(error) {
                statusMessage = "Offline — using cached transmitters"
            } else {
                lastError = error.localizedDescription
                statusMessage = "Transmitter fetch failed"
            }
        }
    }

    func importTLEText(_ text: String) {
        let imported = GPService.parseElementText(text)
        guard !imported.isEmpty else {
            lastError = "No usable elements were found. Supported formats: OMM (JSON, XML, or CSV) and classic TLE."
            return
        }

        var map = Dictionary(uniqueKeysWithValues: satellites.map { ($0.id, $0) })
        for var record in imported {
            if let old = map[record.id] {
                record.transponders = old.transponders
            }
            map[record.id] = record
        }
        satellites = mergeLocalCatalog(Array(map.values)).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        normalizeSelection()
        statusMessage = "Imported \(imported.count) element set\(imported.count == 1 ? "" : "s")"
    }

    func loadTransponders(for norad: UInt) async {
        do {
            let records = try await TransponderService.fetch(norad: norad)
            guard let index = satellites.firstIndex(where: { $0.id == norad }) else { return }
            let manual = preferences.manualTransponders?[String(norad)] ?? []
            satellites[index].transponders = mergeTransponderLists(records, manual)
            statusMessage = "Loaded \(records.count) SatNOGS transmitters"
        } catch {
            // Offline transponder loads are silent — cached/bundled data still applies.
            if !Self.isOffline(error) { lastError = error.localizedDescription }
        }
    }


    /// Refresh space weather only when it is missing or older than `maxAge`
    /// (NOAA's planetary Kp updates every ~3 hours; an hourly ceiling keeps the
    /// indices current without hammering the feeds). Call freely on screen entry
    /// and on app foregrounding.
    func refreshSpaceWeatherIfNeeded(maxAge: TimeInterval = 3600) async {
        // A fresh-enough snapshot short-circuits — but only if it actually carries
        // the geomagnetic indices. A cached snapshot missing Kp/A (e.g. saved
        // before a feed-format fix) must not block a corrective refresh.
        if let snap = spaceWeather,
           Date().timeIntervalSince(snap.fetchedAt) < maxAge,
           snap.kp != nil, snap.aIndex != nil { return }
        await refreshSpaceWeather()
    }

    func refreshSpaceWeather() async {
        do {
            let snapshot = try await SpaceWeatherService.fetch()
            spaceWeather = snapshot
            try Self.ensureApplicationSupport()
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.spaceWeatherCacheURL, options: .atomic)
            }
        } catch {
            // Space weather is ancillary and refreshes automatically — never pop an
            // alert (especially offline); the indices just stay on the cached values.
            statusMessage = Self.isOffline(error) ? "Offline — space weather not updated" : "Space weather update failed"
        }
    }

    func addSavedSite(_ site: ObserverSite) {
        var sites = preferences.savedSites ?? []
        let base = site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Site" : site.name
        var unique = base
        var suffix = 2
        let existing = Set(([preferences.observer.name] + sites.map(\.name)).map { $0.lowercased() })
        while existing.contains(unique.lowercased()) {
            unique = "\(base) \(suffix)"
            suffix += 1
        }
        var copy = site
        copy.name = unique
        sites.append(copy)
        preferences.savedSites = sites
    }

    func removeSavedSite(at offsets: IndexSet) {
        var sites = preferences.savedSites ?? []
        sites.remove(atOffsets: offsets)
        preferences.savedSites = sites
    }

    func makePrimarySite(_ site: ObserverSite) {
        // Choosing an explicit site is a request for a fixed station. Stop following
        // the device first, otherwise the next GPS fix would immediately overwrite
        // the chosen site (and leave it renamed "Current location").
        preferences.locationMode = .fixed
        preferences.savedFixedSite = nil
        preferences.observer = site
    }

    func addOrUpdateSatellite(_ record: SatelliteRecord, favorite: Bool = true) {
        if let index = satellites.firstIndex(where: { $0.id == record.id }) {
            var merged = record
            if merged.transponders.isEmpty { merged.transponders = satellites[index].transponders }
            satellites[index] = merged
        } else {
            satellites.append(record)
            satellites.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        if favorite { preferences.favorites.insert(record.id) }
        preferences.selectedNorad = record.id
    }

    /// Cache key for transmitters filed under a SatNOGS sat_id.
    nonisolated static func satnogsKey(_ satID: String) -> String { "satnogs:\(satID)" }

    func addExtraSatellite(_ record: SatelliteRecord, transponders: [TransponderRecord],
                           satnogsID: String? = nil, placeholderNorad: Bool = false) {
        var extras = preferences.extraSatellites ?? []
        var definition = ManualSatelliteDefinition(record: record)
        definition.satnogsID = satnogsID
        definition.placeholderNorad = placeholderNorad ? true : nil
        if let index = extras.firstIndex(where: { $0.norad == record.id }) {
            extras[index] = definition
        } else {
            extras.append(definition)
        }
        preferences.extraSatellites = extras
        var merged = record
        merged.isManual = false
        merged.transponders = transponders
        addOrUpdateSatellite(merged, favorite: true)
        statusMessage = "Added \(record.name) to my satellites"
    }


    func saveManualSatellite(_ definition: ManualSatelliteDefinition, replacing oldNorad: UInt? = nil) {
        var definitions = preferences.manualSatellites ?? []
        if let oldNorad, oldNorad != definition.norad {
            definitions.removeAll { $0.norad == oldNorad }
            satellites.removeAll { $0.id == oldNorad && $0.isManual }
            if preferences.favorites.remove(oldNorad) != nil {
                preferences.favorites.insert(definition.norad)
            }
            var tx = preferences.manualTransponders ?? [:]
            if let moved = tx.removeValue(forKey: String(oldNorad)), !moved.isEmpty {
                tx[String(definition.norad)] = moved
                preferences.manualTransponders = tx
            }
        }
        if let index = definitions.firstIndex(where: { $0.norad == definition.norad }) {
            definitions[index] = definition
        } else {
            definitions.append(definition)
        }
        preferences.manualSatellites = definitions
        let record = applyManualTransponders(to: GPService.makeManualRecord(definition))
        addOrUpdateSatellite(record, favorite: true)
        statusMessage = "Saved manual satellite \(definition.name)"
    }

    func deleteManualSatellite(_ norad: UInt) {
        var definitions = preferences.manualSatellites ?? []
        definitions.removeAll { $0.norad == norad }
        preferences.manualSatellites = definitions
        var tx = preferences.manualTransponders ?? [:]
        tx.removeValue(forKey: String(norad))
        preferences.manualTransponders = tx
        satellites.removeAll { $0.id == norad && $0.isManual }
        preferences.favorites.remove(norad)
        normalizeSelection()
        statusMessage = "Deleted manual satellite"
    }

    func addManualTransponder(_ transponder: TransponderRecord, to norad: UInt) {
        var all = preferences.manualTransponders ?? [:]
        var list = all[String(norad)] ?? []
        if let index = list.firstIndex(where: { $0.id == transponder.id }) {
            list[index] = transponder
        } else {
            list.append(transponder)
        }
        all[String(norad)] = list
        preferences.manualTransponders = all
        if let index = satellites.firstIndex(where: { $0.id == norad }) {
            satellites[index].transponders = mergeTransponderLists(satellites[index].transponders, list)
        }
        statusMessage = "Saved manual transponder"
    }

    func deleteManualTransponder(id: String, from norad: UInt) {
        var all = preferences.manualTransponders ?? [:]
        var list = all[String(norad)] ?? []
        list.removeAll { $0.id == id }
        all[String(norad)] = list
        preferences.manualTransponders = all
        if let index = satellites.firstIndex(where: { $0.id == norad }) {
            satellites[index].transponders.removeAll { $0.id == id }
        }
    }

    func manualTransponders(for norad: UInt) -> [TransponderRecord] {
        preferences.manualTransponders?[String(norad)] ?? []
    }

    var operatorGrid: String {
        FeatureEngine.latLonToGrid4(latitude: preferences.observer.latitude,
                                    longitude: preferences.observer.longitude)
    }
    
    // UUID that is generated once (lazily) and stored for lifetime of the app
    var installationUUID: String {
        if let storedUUID = defaults.string(forKey: "OrbitDeckIOS.installationUUID") {
            return storedUUID
        } else {
            // if we dont have any UUID yet, generate and store new one
            let newUUID = UUID().uuidString
            defaults.set(newUUID, forKey: "OrbitDeckIOS.installationUUID")
            return newUUID
        }
    }

    /// Six-character station locator for display.
    var operatorGrid6: String {
        FeatureEngine.latLonToGrid6(latitude: preferences.observer.latitude,
                                    longitude: preferences.observer.longitude)
    }

    /// Every 4-character VUCC grid the station may currently claim (more than one
    /// when sitting on a grid line or corner).
    var operatorVuccGrids: [String] {
        FeatureEngine.vuccGrids(latitude: preferences.observer.latitude,
                                longitude: preferences.observer.longitude)
    }

    /// The operator's saved radio calibration for a satellite (zero if none).
    func calibration(for norad: UInt) -> RadioCalibration {
        preferences.satelliteCalibrations?[String(norad)] ?? RadioCalibration()
    }

    /// Persist (or clear, when zero) the operator's radio calibration for a
    /// satellite. Stored per-satellite so each bird keeps its own correction.
    func setCalibration(_ calibration: RadioCalibration, for norad: UInt) {
        var dict = preferences.satelliteCalibrations ?? [:]
        if calibration.isZero { dict[String(norad)] = nil } else { dict[String(norad)] = calibration }
        preferences.satelliteCalibrations = dict.isEmpty ? nil : dict
    }

    /// The single downlink-referred calibration correction for a satellite, for any
    /// live Doppler readout. The operator's calibration is a combined oscillator
    /// error measurable from either leg; both offsets fold into the receive dial
    /// (uplink sign-flipped on an inverting transponder), and nothing is added to
    /// the transmit dial.
    func downlinkCalibrationHz(for norad: UInt, invert: Bool) -> Double {
        let c = calibration(for: norad)
        return c.downlinkHz + (invert ? -1.0 : 1.0) * c.uplinkHz
    }

    var locationMode: LocationMode { preferences.locationMode ?? .fixed }

    /// The name used for the observer while following the device.
    static let currentLocationName = "Current location"

    /// Switch between a fixed primary site and following the device. Preserves the
    /// operator's fixed site across the round trip: entering "current location"
    /// stashes the fixed site and renames the active observer; returning restores
    /// it. Coordinates are then filled in by `applyCurrentLocation` from a fix.
    func setLocationMode(_ mode: LocationMode) {
        guard mode != locationMode else { return }
        switch mode {
        case .currentLocation:
            preferences.savedFixedSite = preferences.observer
            preferences.observer.name = Self.currentLocationName
            preferences.locationMode = .currentLocation
            refreshLocationEntity()
        case .fixed:
            if let fixed = preferences.savedFixedSite { preferences.observer = fixed }
            preferences.savedFixedSite = nil
            preferences.locationMode = .fixed
            currentLocationEntity = nil
            lastGeocodeKey = nil
        }
    }

    /// Update the observer from a live device fix while in current-location mode.
    /// Keeps the "Current location" name so it never masquerades as the fixed site.
    func applyCurrentLocation(latitude: Double, longitude: Double, altitudeMeters: Double) {
        preferences.observer.name = Self.currentLocationName
        preferences.observer.latitude = max(-90, min(90, latitude))
        var lon = longitude.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 }
        if lon < -180 { lon += 360 }
        preferences.observer.longitude = lon
        if altitudeMeters.isFinite { preferences.observer.altitudeMeters = altitudeMeters }
        refreshLocationEntity()
    }

    /// Reverse-geocode the current observer position into `currentLocationEntity`,
    /// but only in current-location mode and only when the ~1 km-rounded position
    /// changes (so we don't spam the geocoder on coarse-fix jitter). Runs off the
    /// view layer so the result survives view re-renders and never depends on a
    /// conditionally-rendered view's lifecycle.
    func refreshLocationEntity() {
        guard locationMode == .currentLocation else {
            currentLocationEntity = nil
            lastGeocodeKey = nil
            return
        }
        let o = preferences.observer
        let key = String(format: "%.2f,%.2f", o.latitude, o.longitude)
        guard key != lastGeocodeKey else { return }
        lastGeocodeKey = key
        let lat = o.latitude, lon = o.longitude
        Task { [weak self] in
            let result = await GeoEntityLookup.lookup(latitude: lat, longitude: lon)
            guard let self else { return }
            // Ignore a stale result if the operator has since left current mode.
            guard self.locationMode == .currentLocation else { return }
            if let result { self.currentLocationEntity = result }
        }
    }

    func clearError() {
        lastError = nil
    }

    private func normalizeSelection() {
        guard !satellites.isEmpty else {
            preferences.selectedNorad = nil
            return
        }
        if preferences.selectedNorad == nil ||
            !satellites.contains(where: { $0.id == preferences.selectedNorad }) {
            preferences.selectedNorad = satellites.first?.id
        }
    }

    private func mergeTransponders(old: [SatelliteRecord], new: [SatelliteRecord]) -> [SatelliteRecord] {
        var tx: [UInt: [TransponderRecord]] = [:]
        for record in old { tx[record.id] = record.transponders }
        return new.map { record in
            var r = record
            r.transponders = tx[record.id] ?? []
            return r
        }
    }


    private func mergeLocalCatalog(_ downloaded: [SatelliteRecord]) -> [SatelliteRecord] {
        // Be tolerant of duplicate NORAD IDs in imported/custom catalogs: the
        // last record wins instead of Dictionary(uniqueKeysWithValues:) trapping.
        var map: [UInt: SatelliteRecord] = [:]
        for record in downloaded { map[record.id] = applyManualTransponders(to: record) }
        for definition in preferences.extraSatellites ?? [] where map[definition.norad] == nil {
            map[definition.norad] = applyManualTransponders(to: GPService.makeExtraRecord(definition))
        }
        for definition in preferences.manualSatellites ?? [] {
            map[definition.norad] = applyManualTransponders(to: GPService.makeManualRecord(definition))
        }
        return map.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func applyManualTransponders(to record: SatelliteRecord) -> SatelliteRecord {
        var record = record
        let key = String(record.id)
        // New-launch extras are linked to SatNOGS by sat_id; fall back to that.
        let satnogsID = preferences.extraSatellites?.first { $0.norad == record.id }?.satnogsID
        let cached = allTransponders[key] ?? satnogsID.flatMap { allTransponders[Self.satnogsKey($0)] } ?? []
        let manual = preferences.manualTransponders?[key] ?? []
        record.transponders = mergeTransponderLists(mergeTransponderLists(record.transponders, cached), manual)
        return record
    }

    private func mergeTransponderLists(_ first: [TransponderRecord], _ second: [TransponderRecord]) -> [TransponderRecord] {
        var byID: [String: TransponderRecord] = [:]
        for item in first { byID[item.id] = item }
        for item in second { byID[item.id] = item }
        return byID.values.sorted {
            // Two-way transponders (uplink + downlink) come first, then alphabetical.
            // Active before inactive (SatNOGS keeps dead transmitters on file),
            // so the default pick is something actually on the air.
            // The ID tie-break keeps same-named transponders in a fixed order;
            // dictionary iteration order varies, which reshuffled picker menus.
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.isTwoWay != $1.isTwoWay { return $0.isTwoWay }
            let byName = $0.description.localizedCaseInsensitiveCompare($1.description)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private func loadPreferences() {
        guard let data = defaults.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode(StorePreferences.self, from: data) else {
            return
        }
        preferences = decoded
        // Called from init, where `didSet` doesn't fire: apply the display settings here.
        ODFormat.useLocalTime = decoded.useLocalTime ?? false
        ODFormat.unitSystem = decoded.unitSystem ?? .system
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: prefsKey)
    }

    private static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OrbitDeck", isDirectory: true)
    }

    static var gpCacheURL: URL {
        applicationSupportURL.appendingPathComponent("gp.json")
    }

    static var spaceWeatherCacheURL: URL {
        applicationSupportURL.appendingPathComponent("space-weather.json")
    }

    static var transpondersCacheURL: URL {
        applicationSupportURL.appendingPathComponent("transponders.json")
    }

    private static func ensureApplicationSupport() throws {
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
    }
}


// MARK: - Secret storage

enum OrbitSecret: String, CaseIterable {
    case qrzPassword = "qrz-password"
    case spaceTrackPassword = "spacetrack-password"
    // Personal hams.at API key (from the hams.at Settings page), used only to
    // post activation alerts you explicitly confirm. Kept in the Keychain.
    case hamsatApiKey = "hamsat-api-key"
    // Icom network (RS-BA1) CAT passwords, per configured radio slot.
    case rigPassword0 = "rig-password-0"
    case rigPassword1 = "rig-password-1"
    // Logging upload secrets.
    case lotwP12Passphrase = "lotw-p12-passphrase"   // passphrase for the imported LoTW .p12
    case cloudlogKey = "cloudlog-api-key"            // Cloudlog/Wavelog read-write API key
}

enum OrbitSecretStore {
    private static let service = "org.orbitdeck.ios"

    static func set(_ value: String, for secret: OrbitSecret) {
#if canImport(Security)
        let account = secret.rawValue
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
#else
        // Validation-host fallback only. iOS uses Keychain above.
        UserDefaults.standard.set(value, forKey: "OrbitDeck.validation.\(secret.rawValue)")
#endif
    }

    static func get(_ secret: OrbitSecret) -> String {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: secret.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
#else
        return UserDefaults.standard.string(forKey: "OrbitDeck.validation.\(secret.rawValue)") ?? ""
#endif
    }

    /// Delete a single stored secret.
    static func remove(_ secret: OrbitSecret) { set("", for: secret) }

    /// Wipe every OrbitDeck secret from the Keychain. iOS Keychain items survive app
    /// deletion and reappear on reinstall, so this gives the operator an explicit way to
    /// clear stored passwords/API keys (e.g. handing the device on, or switching accounts).
    static func clearAll() {
#if canImport(Security)
        // Delete by service so nothing is missed even if a key predates CaseIterable.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
#else
        for s in OrbitSecret.allCases { UserDefaults.standard.removeObject(forKey: "OrbitDeck.validation.\(s.rawValue)") }
#endif
    }
}

// MARK: - Automatic satellite switching

/// One switch the auto-switcher made (live) or would make (plan).
struct AutoSwitchEvent: Identifiable, Sendable {
    let id: Int
    let date: Date
    let norad: UInt
    let reason: AutoSwitchReason
}

/// SatPC32-style automatic satellite switching (its "A+" mode). While enabled it
/// checks the priority satellites every 2 s and changes the app-wide selection
/// per `AutoSwitchRules`, so Home, CAT Doppler and the rotator all follow.
/// It runs its own loop (started from attach) rather than a view `.task`, so it
/// keeps working whichever screen is showing.
@MainActor
final class AutoSwitchController: ObservableObject {
    static let defaultsKey = "OrbitDeckIOS.autoSwitch"
    static let tickInterval: Duration = .seconds(2)
    /// How long a manual pick of a satellite that isn't up holds auto switching.
    static let manualHoldGrace: TimeInterval = 15 * 60

    @Published var settings: AutoSwitchSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            manualHold = nil
            if settings.enabled != oldValue.enabled { restartLoop() } else { tick() }
        }
    }
    @Published private(set) var status = "Off"
    @Published private(set) var lastEvent: AutoSwitchEvent?
    /// The next switch the rules will make (from a background simulation of the
    /// coming hours), for the Home banner. nil when none is due in the window.
    @Published private(set) var nextSwitch: AutoSwitchEvent?
    private var planKey = ""
    private var plannedAt = Date.distantPast
    private var planning = false
    nonisolated static let lookAheadHours = 6.0

    private weak var store: OrbitStore?
    private var loop: Task<Void, Never>?
    private var lastAutoSelection: UInt?
    private var lastSeenSelection: UInt?
    private var currentWasInRange = false
    private var manualHold: (norad: UInt, since: Date)?
    private var eventCounter = 0

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(AutoSwitchSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AutoSwitchSettings()
        }
    }

    func attach(_ store: OrbitStore) {
        self.store = store
        restartLoop()
    }

    /// Switch-in elevation for rule 1.
    func threshold(for store: OrbitStore) -> Double {
        settings.useGlobalMinElevation ? store.preferences.minElevation : settings.minElevation
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = nil
        lastAutoSelection = nil
        lastSeenSelection = nil
        currentWasInRange = false
        nextSwitch = nil; planKey = ""
        guard settings.enabled, store != nil else { setStatus("Off"); return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    private func setStatus(_ text: String) {
        if status != text { status = text }   // avoid republishing every tick
    }

    func tick(now: Date = .now) {
        guard settings.enabled, let store else { return }
        let observer = store.preferences.observer
        let selected = store.preferences.selectedNorad
        let satellites = store.satellites

        func elevation(_ norad: UInt) -> Double? {
            guard let record = satellites.first(where: { $0.id == norad }) else { return nil }
            return try? OrbitPredictor.look(record, observer: observer, at: now).elevation
        }
        func name(_ norad: UInt) -> String { satellites.first { $0.id == norad }?.name ?? "#\(norad)" }

        // A selection change the switcher didn't make is a manual pick. (The first
        // tick after enabling only records the baseline.)
        if selected != lastSeenSelection {
            if lastSeenSelection != nil, selected != lastAutoSelection, let selected, settings.holdManualSelection {
                manualHold = (selected, now)
            }
            lastSeenSelection = selected
            currentWasInRange = selected.flatMap(elevation).map { $0 >= 0 } ?? false
        }

        if let hold = manualHold {
            let up = (elevation(hold.norad) ?? -1) >= 0
            if hold.norad == selected, up || now.timeIntervalSince(hold.since) < Self.manualHoldGrace {
                setStatus("Paused for your selection of \(name(hold.norad))")
                return
            }
            manualHold = nil
        }

        func elevation(_ norad: UInt, at t: Date) -> Double? {
            guard let record = satellites.first(where: { $0.id == norad }) else { return nil }
            return try? OrbitPredictor.look(record, observer: observer, at: t).elevation
        }
        let candidates = settings.priorities.enumerated().compactMap { rank, norad -> AutoSwitchCandidate? in
            guard let el = elevation(norad) else { return nil }
            let later = elevation(norad, at: now.addingTimeInterval(20)) ?? el
            return AutoSwitchCandidate(norad: norad, rank: rank, elevation: el, rising: later > el)
        }
        let floor = threshold(for: store)
        let rangeFloor = min(0, settings.preemptElevation)
        if let decision = AutoSwitchRules.decide(current: selected, currentWasInRange: currentWasInRange,
                                                 candidates: candidates, threshold: floor,
                                                 preemption: settings.preemption,
                                                 preemptElevation: settings.preemptElevation) {
            store.select(decision.norad)
            lastAutoSelection = decision.norad
            lastSeenSelection = decision.norad
            eventCounter += 1
            lastEvent = AutoSwitchEvent(id: eventCounter, date: now, norad: decision.norad, reason: decision.reason)
            currentWasInRange = (candidates.first { $0.norad == decision.norad }?.elevation ?? -90) >= rangeFloor
        } else {
            currentWasInRange = (candidates.first { $0.norad == selected }?.elevation ?? -90) >= rangeFloor
        }

        let active = store.preferences.selectedNorad
        if let current = candidates.first(where: { $0.norad == active }), current.elevation >= rangeFloor {
            setStatus("Tracking \(name(current.norad)) · priority \(current.rank + 1)")
        } else if settings.priorities.isEmpty {
            setStatus("Add priority satellites to start")
        } else {
            setStatus("Waiting for a priority satellite to reach \(ODFormat.angle(floor, decimals: 0))")
        }
        refreshPlanIfNeeded(now: now, store: store)
    }

    /// Re-simulate the coming hours in the background when the inputs change, a
    /// planned switch has come due, or every 5 minutes, and publish the next switch.
    private func refreshPlanIfNeeded(now: Date, store: OrbitStore) {
        let selected = store.preferences.selectedNorad
        let threshold = threshold(for: store)
        let key = "\(settings.priorities)|\(threshold)|\(settings.preemption.rawValue)|\(settings.preemptElevation)|\(store.preferences.observer.stableKey)|\(selected ?? 0)|\(store.satellites.count)"
        let due = nextSwitch.map { $0.date <= now } ?? false
        guard !planning, key != planKey || due || now.timeIntervalSince(plannedAt) > 300 else { return }
        planning = true; planKey = key; plannedAt = now
        let records = settings.priorities.compactMap { id in store.satellites.first { $0.id == id } }
        let observer = store.preferences.observer
        let preemption = settings.preemption, preemptElevation = settings.preemptElevation
        Task { [weak self] in
            let events = await Task.detached(priority: .utility) {
                AutoSwitchController.plan(priorities: records, observer: observer, from: now,
                                          hours: Self.lookAheadHours, threshold: threshold, preemption: preemption,
                                          preemptElevation: preemptElevation, initial: selected).events
            }.value
            guard let self else { return }
            self.planning = false
            guard self.settings.enabled else { self.nextSwitch = nil; return }
            // Skip anything the live loop is about to do this instant.
            self.nextSwitch = events.first { $0.date > now.addingTimeInterval(5) }
        }
    }

    /// Simulate the rules over the next `hours` with the current settings, so the
    /// panel can show which satellite would be active when passes overlap.
    /// CPU-bound: call from a detached task.
    nonisolated static func plan(priorities: [SatelliteRecord], observer: ObserverSite, from start: Date,
                                 hours: Double, threshold: Double,
                                 preemption: AutoSwitchSettings.Preemption,
                                 preemptElevation: Double = 0,
                                 initial: UInt?) -> (passes: [TimelinePass], spans: [TimelineSpan], events: [AutoSwitchEvent]) {
        let end = start.addingTimeInterval(hours * 3600)
        // A pre-AOS switch elevation needs elevations just below the horizon, so
        // sample a few minutes either side of each pass (≈1°/10 s near the horizon on LEO).
        let padding: TimeInterval = preemptElevation < 0 ? max(120, -preemptElevation * 60) : 0
        let passes = PassTimeline.load(priorities.enumerated().map { (record: $0.element, colorIndex: $0.offset) },
                                       observer: observer, from: start, to: end, padding: padding)
        let bySat = Dictionary(grouping: passes, by: \.norad)
        // Outside every sampled window the satellite is well below the horizon.
        func elevation(_ norad: UInt, _ t: Date) -> Double {
            bySat[norad]?.lazy.compactMap { $0.elevation(at: t) }.first ?? -90
        }
        let rangeFloor = min(0, preemptElevation)
        let names = Dictionary(priorities.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let rank = Dictionary(priorities.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })

        var current = initial
        var wasInRange = current.map { elevation($0, start) >= 0 } ?? false
        var events: [AutoSwitchEvent] = []
        var spans: [TimelineSpan] = []
        var openSpan: (norad: UInt, start: Date)?
        let step: TimeInterval = 30

        func closeSpan(at t: Date) {
            guard let open = openSpan else { return }
            spans.append(TimelineSpan(id: spans.count, norad: open.norad, name: names[open.norad] ?? "",
                                      colorIndex: rank[open.norad] ?? 0, start: open.start, end: t))
            openSpan = nil
        }

        var t = start
        while t <= end {
            let candidates = priorities.enumerated().map {
                let el = elevation($0.element.id, t)
                return AutoSwitchCandidate(norad: $0.element.id, rank: $0.offset, elevation: el,
                                           rising: elevation($0.element.id, t.addingTimeInterval(step)) > el)
            }
            if let d = AutoSwitchRules.decide(current: current, currentWasInRange: wasInRange, candidates: candidates,
                                              threshold: threshold, preemption: preemption,
                                              preemptElevation: preemptElevation) {
                current = d.norad
                events.append(AutoSwitchEvent(id: events.count, date: t, norad: d.norad, reason: d.reason))
            }
            let el = current.map { elevation($0, t) } ?? -90
            let rising = current.map { elevation($0, t.addingTimeInterval(step)) > el } ?? false
            wasInRange = el >= 0 || (rising && el >= rangeFloor)
            let up = el >= 0
            // The plan strip shows a satellite while it is both selected and up.
            let active: UInt? = up ? current : nil
            if openSpan?.norad != active {
                closeSpan(at: t)
                if let active, rank[active] != nil { openSpan = (active, t) }
            }
            t = t.addingTimeInterval(step)
        }
        closeSpan(at: end)
        return (passes, spans, events)
    }
}

// MARK: - Live Activity (Dynamic Island)

#if canImport(ActivityKit)
/// KEEP IN SYNC with the copy in OrbitDeckWidgets/OrbitDeckWidgets.swift: the
/// widget extension decodes this by type name and Codable shape.
struct OrbitDeckPassAttributes: ActivityAttributes {
    enum Source: String, Codable, Hashable {
        case priority
        case favorite
    }

    struct ContentState: Codable, Hashable {
        var satellite: String
        var aos: Date
        var los: Date
        var maxElevation: Double
        var switchAt: Date?
        var source: Source
        var inPass: Bool
        var utc: Bool
    }
}

/// Keeps one Live Activity showing the next pass: with auto switching on, the
/// satellite the priority list switches to next (and when); otherwise the next
/// AOS, or the LOS of a pass in progress, among the favorites. The countdown in
/// the activity is timer text, so it keeps counting while the app is suspended;
/// the content itself refreshes whenever the app runs.
@MainActor
final class LiveActivityController: ObservableObject {
    static let enabledKey = "liveActivityEnabled"
    static let refreshInterval: Duration = .seconds(30)

    /// On by default; the Settings toggle writes this key through @AppStorage.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private weak var store: OrbitStore?
    private weak var autoSwitch: AutoSwitchController?
    private var loop: Task<Void, Never>?
    private var computing = false
    private var lastKey = ""
    private var computedAt = Date.distantPast
    private var state: OrbitDeckPassAttributes.ContentState?

    func attach(store: OrbitStore, autoSwitch: AutoSwitchController) {
        self.store = store
        self.autoSwitch = autoSwitch
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// Recompute when the inputs change, the shown pass reaches AOS or LOS, or
    /// every 10 minutes; then start, update or end the activity to match.
    func refresh(now: Date = .now) async {
        guard let store, let autoSwitch else { return }
        guard Self.isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            state = nil; lastKey = ""
            await Self.apply(nil, canStart: false)
            return
        }
        let usePriorities = autoSwitch.settings.enabled && !autoSwitch.settings.priorities.isEmpty
        let ids: [UInt] = usePriorities ? autoSwitch.settings.priorities : store.preferences.favorites.sorted()
        let next = usePriorities ? autoSwitch.nextSwitch : nil
        let minimum = usePriorities ? autoSwitch.threshold(for: store) : store.preferences.minElevation
        let utc = !ODFormat.useLocalTime
        let key = "\(usePriorities)|\(ids)|\(store.preferences.observer.stableKey)|\(minimum)|\(next?.norad ?? 0)|\(next?.date.timeIntervalSince1970 ?? 0)|\(store.satellites.count)|\(utc)"
        let expired = state.map { $0.los <= now || (!$0.inPass && $0.aos <= now) } ?? false
        if key != lastKey || expired || now.timeIntervalSince(computedAt) > 600, !computing {
            computing = true
            lastKey = key; computedAt = now
            let records = ids.compactMap { id in store.satellites.first { $0.id == id } }
            let observer = store.preferences.observer
            let switchRecord = next.flatMap { n in store.satellites.first { $0.id == n.norad } }
            let switchDate = next?.date
            state = await Task.detached(priority: .utility) {
                Self.compute(records: records, switchRecord: switchRecord, switchDate: switchDate,
                             usePriorities: usePriorities, observer: observer, minElevation: minimum,
                             utc: utc, now: now)
            }.value
            computing = false
        }
        // Live Activities can only be started from the foreground; one ended by
        // the system's time limit restarts the next time the app is opened.
        await Self.apply(state, canStart: UIApplication.shared.applicationState == .active)
    }

    /// CPU-bound (SGP4): call from a detached task.
    nonisolated static func compute(records: [SatelliteRecord], switchRecord: SatelliteRecord?, switchDate: Date?,
                                    usePriorities: Bool, observer: ObserverSite, minElevation: Double,
                                    utc: Bool, now: Date) -> OrbitDeckPassAttributes.ContentState? {
        let source: OrbitDeckPassAttributes.Source = usePriorities ? .priority : .favorite
        // A planned switch: that satellite's pass that is still up at the switch time
        // (the switch can come before AOS with a negative take-over elevation).
        if let switchRecord, let switchDate,
           let pass = (try? OrbitPredictor.predictPasses(switchRecord, observer: observer, from: now,
                                                        minElevation: 0, maxCount: 3, horizonDays: 1))?
            .first(where: { $0.los > switchDate }) {
            return OrbitDeckPassAttributes.ContentState(
                satellite: switchRecord.name, aos: pass.aos, los: pass.los, maxElevation: pass.maxElevation,
                switchAt: switchDate, source: source, inPass: pass.aos <= now, utc: utc)
        }
        // Otherwise the earliest pass (in progress first) among the candidates.
        // Passes longer than 12 h are always-visible high orbits, which would
        // otherwise pin the activity forever.
        var best: (record: SatelliteRecord, pass: PredictedPass)?
        for record in records {
            guard let pass = (try? OrbitPredictor.predictPasses(record, observer: observer, from: now,
                                                               minElevation: minElevation, maxCount: 2,
                                                               horizonDays: 2))?
                .first(where: { $0.duration < 12 * 3600 && $0.los > now }) else { continue }
            if best.map({ pass.aos < $0.pass.aos }) ?? true { best = (record, pass) }
        }
        guard let best else { return nil }
        return OrbitDeckPassAttributes.ContentState(
            satellite: best.record.name, aos: best.pass.aos, los: best.pass.los,
            maxElevation: best.pass.maxElevation, switchAt: nil, source: source,
            inPass: best.pass.aos <= now, utc: utc)
    }

    /// Nonisolated so the (non-Sendable) Activity objects never cross actors.
    nonisolated private static func apply(_ state: OrbitDeckPassAttributes.ContentState?, canStart: Bool) async {
        let running = Activity<OrbitDeckPassAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        guard let state else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        // Stale at the next transition, so the widget flips to the LOS countdown at
        // AOS even if the app can't refresh then.
        let content = ActivityContent(state: state, staleDate: state.inPass ? state.los : state.aos)
        if let activity = running.first {
            for extra in running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
            if activity.content.state != state || activity.activityState == .stale {
                await activity.update(content)
            }
        } else if canStart {
            _ = try? Activity.request(attributes: OrbitDeckPassAttributes(), content: content)
        }
    }
}
#endif
