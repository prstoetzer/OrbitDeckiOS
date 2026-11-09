import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Security)
import Security
#endif
#if canImport(ActivityKit)
import ActivityKit
import BackgroundTasks
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
    private let prefsKey = OrbitStore.preferencesKey
    nonisolated static let preferencesKey = "OrbitDeckIOS.preferences.v1"
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

    // Per-transponder refinement (FT4 echo auto-calibration). Different transponders on
    // one satellite can have different LO errors, so the FT4 auto-cal learns a downlink
    // offset per satellite+transponder, stored ON TOP of the operator's per-satellite
    // calibration: a transponder with no entry uses the per-satellite value unchanged, and
    // a manual per-satellite edit still shifts every transponder. Kept in its own
    // UserDefaults key (a plain [String: Double] JSON dictionary, decoded tolerantly —
    // unreadable data reads as empty) so StorePreferences' schema is untouched.

    private static let transponderCalKey = "orbitdeck.calibration.transponderOffsets"

    private static func transponderCalID(_ norad: UInt, _ transponderID: String) -> String {
        "\(norad)|\(transponderID)"
    }

    private func transponderCalOffsets() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: Self.transponderCalKey),
              let dict = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return dict
    }

    /// The learned extra downlink offset (Hz) for one transponder, or nil when that
    /// transponder has none yet (it then uses the per-satellite calibration as-is).
    func transponderCalibrationOffsetHz(for norad: UInt, transponder transponderID: String) -> Double? {
        transponderCalOffsets()[Self.transponderCalID(norad, transponderID)]
    }

    /// Persist (or clear, with nil) the learned downlink offset for one transponder.
    func setTransponderCalibrationOffsetHz(_ offsetHz: Double?, for norad: UInt, transponder transponderID: String) {
        var dict = transponderCalOffsets()
        dict[Self.transponderCalID(norad, transponderID)] = offsetHz
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.transponderCalKey)
        }
        objectWillChange.send()
    }

    /// The effective calibration for a satellite on a given transponder: the per-satellite
    /// value plus that transponder's learned downlink offset (if any). A nil transponder
    /// is the per-satellite calibration.
    func calibration(for norad: UInt, transponder transponderID: String?) -> RadioCalibration {
        var c = calibration(for: norad)
        if let transponderID, let extra = transponderCalibrationOffsetHz(for: norad, transponder: transponderID) {
            c.downlinkHz += extra
        }
        return c
    }

    /// `downlinkCalibrationHz(for:invert:)` including the transponder's learned offset.
    func downlinkCalibrationHz(for norad: UInt, transponder transponderID: String?, invert: Bool) -> Double {
        let c = calibration(for: norad, transponder: transponderID)
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

    /// Whether a preferences blob already existed when the store was created — i.e. this
    /// is an upgrade or a later launch, not a fresh install. Captured before anything is
    /// saved this launch (RootView uses it to skip the first-run readiness sheet).
    private(set) static var hadPreferencesAtLaunch = false

    private func loadPreferences() {
        Self.hadPreferencesAtLaunch = defaults.data(forKey: prefsKey) != nil
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
        guard !FactoryResetService.didReset, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: prefsKey)
    }

    nonisolated private static var applicationSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OrbitDeck", isDirectory: true)
    }

    nonisolated static var gpCacheURL: URL {
        applicationSupportURL.appendingPathComponent("gp.json")
    }

    /// The cached GP catalog plus custom and new-launch satellites (without
    /// transmitters), limited to `ids`: for work in a background launch, where
    /// bootstrap hasn't run. Mirrors mergeLocalCatalog's precedence.
    nonisolated static func cachedRecords(for ids: Set<UInt>, preferences: StorePreferences) -> [UInt: SatelliteRecord] {
        guard !ids.isEmpty else { return [:] }
        var map: [UInt: SatelliteRecord] = [:]
        if let data = try? Data(contentsOf: gpCacheURL), let records = try? GPService.parse(data: data) {
            for record in records where ids.contains(record.id) { map[record.id] = record }
        }
        for definition in preferences.extraSatellites ?? [] where ids.contains(definition.norad) && map[definition.norad] == nil {
            map[definition.norad] = GPService.makeExtraRecord(definition)
        }
        for definition in preferences.manualSatellites ?? [] where ids.contains(definition.norad) {
            map[definition.norad] = GPService.makeManualRecord(definition)
        }
        return map
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
    case aprsisPasscode = "aprsis-passcode"          // APRS-IS passcode for the packet satgate
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
    nonisolated static let defaultsKey = "OrbitDeckIOS.autoSwitch"
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
            RigController.automaticSelectionNorad = decision.norad   // CAT follows automatic picks
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
        // A pre-AOS switch elevation (negative take-over or switch-in) needs elevations
        // just below the horizon, so sample a few minutes either side of each pass
        // (≈1°/10 s near the horizon on LEO).
        let lowest = min(preemptElevation, threshold)
        let padding: TimeInterval = lowest < 0 ? max(120, -lowest * 60) : 0
        let passes = PassTimeline.load(priorities,
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
                                      start: open.start, end: t))
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
        /// From the auto-switch priority list.
        case priority
        /// The next pass of any favorite.
        case favorite
    }

    /// One pass in the embedded look-ahead list. Short coding keys keep the
    /// content well under the 4 KB ActivityKit limit.
    struct Pass: Codable, Hashable {
        var satellite: String
        var aos: Date
        var los: Date
        var maxElevation: Double
        /// When auto switching selects this satellite (can precede AOS).
        var switchAt: Date?

        enum CodingKeys: String, CodingKey {
            case satellite = "n", aos = "a", los = "l", maxElevation = "e", switchAt = "s"
        }

        /// When this pass becomes the one to show: the switch time, else AOS.
        var start: Date { switchAt ?? aos }
    }

    struct ContentState: Codable, Hashable {
        // The primary pass (the one current when the content was made). Kept for
        // activities and widgets from builds before the look-ahead list.
        var satellite: String
        var aos: Date
        var los: Date
        var maxElevation: Double
        /// When auto switching will select this satellite (can precede AOS).
        var switchAt: Date?
        var source: Source
        /// True when the pass was already in progress at the last update.
        var inPass: Bool
        /// Show times in UTC (the app's default) rather than local time.
        var utc: Bool
        /// The next few passes (the primary one included), so the widget can move
        /// on to the right pass by itself while the app isn't running. Optional:
        /// content from older builds has none and decodes as nil.
        var passes: [Pass]? = nil

        /// The look-ahead list, or just the primary pass for older content.
        var timeline: [Pass] {
            if let passes, !passes.isEmpty { return passes }
            return [Pass(satellite: satellite, aos: aos, los: los, maxElevation: maxElevation, switchAt: switchAt)]
        }

        /// The pass to show at `date`: the one in progress that started last (the
        /// most recent switch), else the next to start; nil once all have ended.
        func pass(at date: Date) -> Pass? {
            let live = timeline.filter { $0.los > date }
            if let current = live.filter({ $0.start <= date }).max(by: { $0.start < $1.start }) {
                return current
            }
            return live.min { $0.start < $1.start }
        }

        /// The next switch, AOS or LOS after `date`, when what to show changes.
        func nextTransition(after date: Date) -> Date? {
            timeline.flatMap { [$0.switchAt, $0.aos, $0.los].compactMap { $0 } }
                .filter { $0 > date }
                .min()
        }
    }
}

/// Keeps one Live Activity showing the next pass: with auto switching on, the
/// satellite the priority list switches to next (and when); otherwise the next
/// AOS, or the LOS of a pass in progress, among the favorites.
///
/// The content carries the next few passes and the widget picks the one to show
/// when it renders, so the activity moves on by itself while the app isn't
/// running; the stale date (the next AOS/LOS/switch) makes the system redraw at
/// each transition. Beyond that it stays current through a background app refresh
/// (at iOS's discretion) and, opt-in on iOS 26+, a scheduled activity for the
/// following pass that iOS starts by itself.
@MainActor
final class LiveActivityController: ObservableObject {
    nonisolated static let enabledKey = "liveActivityEnabled"
    /// Opt-in (iOS 26+): schedule an activity for the following pass that the
    /// system starts on its own, with an alert, even while OrbitDeck is closed.
    nonisolated static let scheduleNextKey = "liveActivityScheduleNext"
    static let refreshInterval: Duration = .seconds(30)
    /// The BGAppRefreshTask; also listed in Info.plist (BGTaskSchedulerPermittedIdentifiers).
    nonisolated static let backgroundRefreshID = "com.prstoetzer.OrbitDeckIOS.liveActivityRefresh"
    /// Passes embedded in the content (a few hundred bytes, far below the 4 KB limit).
    nonisolated static let embeddedPassCount = 4
    /// How long before the switch/AOS a scheduled activity starts.
    nonisolated static let scheduledLead: TimeInterval = 15 * 60
    nonisolated static let currentRelevance = 50.0
    /// Higher, so the Dynamic Island prefers the scheduled pass once it has started.
    nonisolated static let scheduledRelevance = 100.0

    /// On by default; the Settings toggle writes this key through @AppStorage.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    nonisolated static var scheduleNextEnabled: Bool {
        UserDefaults.standard.bool(forKey: scheduleNextKey)
    }

    /// Scheduled (future-start) Live Activities need iOS 26.
    nonisolated static var supportsScheduledStart: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// What the planner needs: captured from the running app, or loaded from disk
    /// when iOS launches the app in the background just for the refresh.
    struct Inputs: Sendable {
        /// The candidates: the priority list (in order) or the favorites.
        var records: [SatelliteRecord]
        var usePriorities: Bool
        var observer: ObserverSite
        /// Switch-in elevation with priorities, else the pass-prediction minimum.
        var minElevation: Double
        var preemption: AutoSwitchSettings.Preemption
        var preemptElevation: Double
        var selected: UInt?
        var utc: Bool
    }

    struct Plan: Sendable {
        /// The running activity's content (nil: nothing to show).
        var current: OrbitDeckPassAttributes.ContentState?
        /// The pass after the current one, for the opt-in scheduled activity.
        var scheduled: OrbitDeckPassAttributes.ContentState?
    }

    /// The attached controller, so a background refresh in a running app reuses
    /// its loaded catalog instead of reading it from disk.
    private static weak var shared: LiveActivityController?

    private weak var store: OrbitStore?
    private weak var autoSwitch: AutoSwitchController?
    private var loop: Task<Void, Never>?
    private var computing = false
    private var lastKey = ""
    private var computedAt = Date.distantPast
    private var plan: Plan?
    /// Reconcile the scheduled activity on the next foreground refresh (set when
    /// the plan changes, the app comes forward or the setting changes), so a
    /// failed request isn't retried every 30 s.
    private var scheduleDirty = true
    /// When the background refresh should next run, and what was last submitted.
    private var wakeTarget: Date?
    private var submittedWake: Date?

    func attach(store: OrbitStore, autoSwitch: AutoSwitchController) {
        self.store = store
        self.autoSwitch = autoSwitch
        Self.shared = self
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// Factory reset: stop refreshing and end any running or scheduled activity (the
    /// cleared defaults read as "enabled", so the loop would otherwise start a new one).
    func stopForFactoryReset() {
        loop?.cancel(); loop = nil
        plan = nil; lastKey = ""
        wakeTarget = nil; submittedWake = nil
        Self.submitBackgroundRefresh(at: nil)
        Task { _ = await Self.apply(nil, canStart: false, manageScheduled: true) }
    }

    func didBecomeActive() {
        scheduleDirty = true
    }

    /// Request a background refresh for the next transition as the app leaves the screen.
    func didEnterBackground() {
        submittedWake = wakeTarget
        Self.submitBackgroundRefresh(at: wakeTarget)
    }

    func scheduleSettingChanged() {
        scheduleDirty = true
        lastKey = ""
        Task { await refresh() }
    }

    /// Recompute when the inputs change, the next transition passes, or every 10
    /// minutes; then start, update or end the activity to match.
    func refresh(now: Date = .now) async {
        guard let store, let autoSwitch, !FactoryResetService.didReset else { return }
        let foreground = UIApplication.shared.applicationState == .active
        guard Self.isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            plan = nil; lastKey = ""
            _ = await Self.apply(nil, canStart: false, manageScheduled: true)
            setWake(nil, foreground: foreground)
            return
        }
        let inputs = Self.inputs(store: store, autoSwitch: autoSwitch)
        let next = inputs.usePriorities ? autoSwitch.nextSwitch : nil
        let ids = inputs.records.map(\.id)
        let key = "\(inputs.usePriorities)|\(ids)|\(inputs.observer.stableKey)|\(inputs.minElevation)|\(inputs.selected ?? 0)|\(next?.norad ?? 0)|\(next?.date.timeIntervalSince1970 ?? 0)|\(store.satellites.count)|\(inputs.utc)"
        let expired = plan?.current?.nextTransition(after: computedAt).map { $0 <= now } ?? false
        if key != lastKey || expired || now.timeIntervalSince(computedAt) > 600, !computing {
            computing = true
            lastKey = key; computedAt = now
            plan = await Task.detached(priority: .utility) { Self.compute(inputs, now: now) }.value
            computing = false
            scheduleDirty = true
        }
        // Live Activities can only be started (or scheduled) from the foreground; one
        // ended by the system's time limit restarts the next time the app is opened.
        let manage = foreground && scheduleDirty
        if manage { scheduleDirty = false }
        let wake = await Self.apply(plan, canStart: foreground, manageScheduled: manage)
        setWake(wake, foreground: foreground)
    }

    /// Remember when the background refresh should run; submit it right away only
    /// while the app is already in the background (it otherwise goes in on the way out).
    private func setWake(_ wake: Date?, foreground: Bool) {
        wakeTarget = wake
        guard !foreground else { return }
        let changed = switch (wake, submittedWake) {
        case (nil, nil): false
        case let (a?, b?): abs(a.timeIntervalSince(b)) > 30
        default: true
        }
        guard changed else { return }
        submittedWake = wake
        Self.submitBackgroundRefresh(at: wake)
    }

    private static func inputs(store: OrbitStore, autoSwitch: AutoSwitchController) -> Inputs {
        let settings = autoSwitch.settings
        let usePriorities = settings.enabled && !settings.priorities.isEmpty
        let ids: [UInt] = usePriorities ? settings.priorities : store.preferences.favorites.sorted()
        return Inputs(records: ids.compactMap { id in store.satellites.first { $0.id == id } },
                      usePriorities: usePriorities, observer: store.preferences.observer,
                      minElevation: usePriorities ? autoSwitch.threshold(for: store) : store.preferences.minElevation,
                      preemption: settings.preemption, preemptElevation: settings.preemptElevation,
                      selected: store.preferences.selectedNorad, utc: !ODFormat.useLocalTime)
    }

    /// The inputs from the attached app, or nil when there is none or its catalog
    /// isn't loaded yet.
    private func liveInputs() -> Inputs? {
        guard let store, let autoSwitch, !store.satellites.isEmpty else { return nil }
        return Self.inputs(store: store, autoSwitch: autoSwitch)
    }

    /// The same inputs read from the saved preferences, auto-switch settings and
    /// cached catalog, for a cold background launch (no UI, no bootstrap).
    nonisolated static func loadSavedInputs() -> Inputs? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: OrbitStore.preferencesKey),
              let preferences = try? JSONDecoder().decode(StorePreferences.self, from: data) else { return nil }
        let settings = defaults.data(forKey: AutoSwitchController.defaultsKey)
            .flatMap { try? JSONDecoder().decode(AutoSwitchSettings.self, from: $0) } ?? AutoSwitchSettings()
        let usePriorities = settings.enabled && !settings.priorities.isEmpty
        let ids: [UInt] = usePriorities ? settings.priorities : preferences.favorites.sorted()
        let catalog = OrbitStore.cachedRecords(for: Set(ids), preferences: preferences)
        // No catalog on disk: don't mistake that for "no passes" and end the activity.
        guard !catalog.isEmpty || ids.isEmpty else { return nil }
        return Inputs(records: ids.compactMap { catalog[$0] }, usePriorities: usePriorities,
                      observer: preferences.observer,
                      minElevation: usePriorities && !settings.useGlobalMinElevation
                        ? settings.minElevation : preferences.minElevation,
                      preemption: settings.preemption, preemptElevation: settings.preemptElevation,
                      selected: preferences.selectedNorad, utc: !(preferences.useLocalTime ?? false))
    }

    /// CPU-bound (SGP4): call from a detached task.
    nonisolated static func compute(_ inputs: Inputs, now: Date) -> Plan {
        typealias Pass = OrbitDeckPassAttributes.Pass
        // One spare, so the scheduled activity also gets a full list.
        let wanted = embeddedPassCount + 1
        func entry(_ record: SatelliteRecord, _ pass: PredictedPass, switchAt: Date?) -> Pass {
            Pass(satellite: String(record.name.prefix(40)), aos: pass.aos, los: pass.los,
                 maxElevation: (pass.maxElevation * 10).rounded() / 10, switchAt: switchAt)
        }
        func samePass(_ a: Pass, _ b: Pass) -> Bool {
            a.satellite == b.satellite && abs(a.aos.timeIntervalSince(b.aos)) < 60
        }
        var list: [Pass] = []
        var planned = false
        if inputs.usePriorities {
            let byID = Dictionary(inputs.records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var cache: [UInt: [PredictedPass]] = [:]
            func passes(_ record: SatelliteRecord) -> [PredictedPass] {
                if let cached = cache[record.id] { return cached }
                let found = (try? OrbitPredictor.predictPasses(record, observer: inputs.observer, from: now,
                                                               minElevation: 0, maxCount: 6, horizonDays: 1)) ?? []
                cache[record.id] = found
                return found
            }
            // The selected priority satellite's pass in progress, so the activity
            // counts down its LOS until the next switch.
            if let selected = inputs.selected, let record = byID[selected],
               let pass = passes(record).first(where: { $0.aos <= now && $0.los > now }) {
                list.append(entry(record, pass, switchAt: nil))
            }
            // The coming switches, each with that satellite's pass still up at the
            // switch time (the switch can come before AOS with a negative take-over).
            let events = AutoSwitchController.plan(priorities: inputs.records, observer: inputs.observer, from: now,
                                                   hours: AutoSwitchController.lookAheadHours,
                                                   threshold: inputs.minElevation, preemption: inputs.preemption,
                                                   preemptElevation: inputs.preemptElevation,
                                                   initial: inputs.selected).events
            for event in events where event.date > now.addingTimeInterval(5) {
                if Task.isCancelled || list.count >= wanted { break }
                guard let record = byID[event.norad],
                      let pass = passes(record).first(where: { $0.los > event.date }) else { continue }
                let item = entry(record, pass, switchAt: event.date)
                // A switch back to a pass already listed (after a higher priority one).
                if list.contains(where: { samePass($0, item) }) { continue }
                list.append(item)
                planned = true
            }
        }
        if !planned {
            // The earliest passes among the candidates. Passes longer than 12 h are
            // always-visible high orbits, which would otherwise pin the activity.
            var all: [Pass] = []
            for record in inputs.records {
                if Task.isCancelled { break }
                let found = (try? OrbitPredictor.predictPasses(record, observer: inputs.observer, from: now,
                                                               minElevation: inputs.minElevation, maxCount: 3,
                                                               horizonDays: 2)) ?? []
                all += found.filter { $0.duration < 12 * 3600 && $0.los > now }
                    .map { entry(record, $0, switchAt: nil) }
            }
            for item in all.sorted(by: { $0.aos < $1.aos }) where list.count < wanted {
                if !list.contains(where: { samePass($0, item) }) { list.append(item) }
            }
        }
        list.sort { $0.start < $1.start }

        let source: OrbitDeckPassAttributes.Source = inputs.usePriorities ? .priority : .favorite
        func state(_ passes: [Pass], at date: Date) -> OrbitDeckPassAttributes.ContentState? {
            guard let first = passes.first else { return nil }
            let probe = OrbitDeckPassAttributes.ContentState(
                satellite: first.satellite, aos: first.aos, los: first.los, maxElevation: first.maxElevation,
                switchAt: first.switchAt, source: source, inPass: false, utc: inputs.utc, passes: passes)
            guard let shown = probe.pass(at: date) else { return nil }
            return OrbitDeckPassAttributes.ContentState(
                satellite: shown.satellite, aos: shown.aos, los: shown.los, maxElevation: shown.maxElevation,
                switchAt: shown.switchAt, source: source, inPass: shown.aos <= date, utc: inputs.utc,
                passes: passes)
        }
        let current = state(Array(list.prefix(embeddedPassCount)), at: now)
        var scheduled: OrbitDeckPassAttributes.ContentState?
        if let current,
           let index = list.firstIndex(where: { $0.satellite == current.satellite && $0.aos == current.aos }),
           index + 1 < list.count {
            let following = Array(list[(index + 1)...].prefix(embeddedPassCount))
            if let first = following.first { scheduled = state(following, at: first.start) }
        }
        return Plan(current: current, scheduled: scheduled)
    }

    /// Start, update or end the running activity to match `plan`, and (from the
    /// foreground) reconcile the scheduled one. Returns when a background refresh
    /// should next run: the next transition, or nil with nothing to keep current.
    /// Nonisolated so the (non-Sendable) Activity objects never cross actors.
    nonisolated private static func apply(_ plan: Plan?, canStart: Bool, manageScheduled: Bool) async -> Date? {
        let now = Date()
        let all = Activity<OrbitDeckPassAttributes>.activities
        // Prefer the highest relevance (a scheduled activity that has started) when
        // collapsing duplicates; the others are leftovers from earlier passes.
        let running = all.filter { $0.activityState == .active || $0.activityState == .stale }
            .sorted { $0.content.relevanceScore > $1.content.relevanceScore }
        var wake: Date?
        if let state = plan?.current {
            // Stale at the next transition, so the system redraws the widget then and
            // it picks the right pass from the embedded list.
            let staleDate = state.nextTransition(after: now) ?? state.los
            if let activity = running.first {
                for extra in running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
                if activity.content.state != state || activity.activityState == .stale {
                    await activity.update(ActivityContent(state: state, staleDate: staleDate,
                                                          relevanceScore: activity.content.relevanceScore))
                }
            } else if canStart {
                _ = try? Activity.request(attributes: OrbitDeckPassAttributes(),
                                          content: ActivityContent(state: state, staleDate: staleDate,
                                                                   relevanceScore: currentRelevance))
            }
            wake = staleDate
        } else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        if #available(iOS 26.0, *) {
            var pending = all.filter { $0.activityState == .pending }
            if manageScheduled {
                let wanted = isEnabled && scheduleNextEnabled ? plan?.scheduled : nil
                pending = await reconcileScheduled(wanted, pending: pending, now: now)
            }
            // Wake shortly after a scheduled activity starts, to fold it together
            // with the running one.
            for activity in pending {
                let start = activity.content.state.timeline.first?.start.addingTimeInterval(-scheduledLead + 60)
                if let start, start > now { wake = min(wake ?? start, start) }
            }
        }
        return wake
    }

    /// Keep at most one pending activity, for `wanted`'s first pass; replace it when
    /// the plan changes. Returns the pending activities left.
    @available(iOS 26.0, *)
    nonisolated private static func reconcileScheduled(_ wanted: OrbitDeckPassAttributes.ContentState?,
                                                       pending: [Activity<OrbitDeckPassAttributes>],
                                                       now: Date) async -> [Activity<OrbitDeckPassAttributes>] {
        guard let wanted, let pass = wanted.timeline.first,
              pass.start.addingTimeInterval(-scheduledLead) > now.addingTimeInterval(60) else {
            // Nothing to schedule, or it's due so soon the running activity covers it.
            for activity in pending { await activity.end(nil, dismissalPolicy: .immediate) }
            return []
        }
        let start = pass.start.addingTimeInterval(-scheduledLead)
        if let match = pending.first(where: { activity in
            activity.content.state.timeline.first.map {
                $0.satellite == pass.satellite && abs($0.aos.timeIntervalSince(pass.aos)) < 60
                    && abs($0.start.timeIntervalSince(pass.start)) < 60
            } ?? false
        }) {
            for other in pending where other.id != match.id { await other.end(nil, dismissalPolicy: .immediate) }
            return [match]
        }
        for activity in pending { await activity.end(nil, dismissalPolicy: .immediate) }
        let minutes = Int((pass.aos.timeIntervalSince(start) / 60).rounded())
        let name = shortName(pass.satellite)
        var body = "AOS \(clock(pass.aos, utc: wanted.utc)), max \(Int(pass.maxElevation.rounded()))°"
        if let switchAt = pass.switchAt { body += ", auto switch at \(clock(switchAt, utc: wanted.utc))" }
        let alert = AlertConfiguration(title: LocalizedStringResource(String.LocalizationValue("\(name) pass in \(minutes) min")),
                                       body: LocalizedStringResource(String.LocalizationValue(body)),
                                       sound: .default)
        let content = ActivityContent(state: wanted, staleDate: wanted.nextTransition(after: start) ?? pass.los,
                                      relevanceScore: scheduledRelevance)
        do {
            let activity = try Activity.request(attributes: OrbitDeckPassAttributes(), content: content,
                                                pushType: nil, style: .standard,
                                                alertConfiguration: alert, start: start)
            return [activity]
        } catch ActivityAuthorizationError.targetMaximumExceeded, ActivityAuthorizationError.globalMaximumExceeded {
            // Too many Live Activities at once (OrbitDeck's or the system's): skip the
            // reminder; the running activity still lists this pass. Retried when the
            // plan changes or the app is next opened.
            return []
        } catch {
            return []
        }
    }

    /// "ISS (ZARYA)" → "ISS", "AO-7_[U/v]" → "AO-7" (as the widget shortens names).
    nonisolated private static func shortName(_ name: String) -> String {
        let cut = name.firstIndex { $0 == "(" || $0 == "[" || $0 == "_" } ?? name.endIndex
        let short = name[..<cut].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    nonisolated private static func clock(_ date: Date, utc: Bool) -> String {
        let formatter = DateFormatter()
        if utc {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm'Z'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        } else {
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    // MARK: Background refresh

    /// Register the BGAppRefreshTask handler. Must run before launch finishes (App.init).
    /// Nonisolated, so the handler (called on a background queue) isn't main-actor isolated.
    nonisolated static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshID, using: nil) { task in
            handleBackgroundRefresh(task)
        }
    }

    /// Ask iOS to wake the app at `date` (no earlier; when exactly is up to iOS), or
    /// cancel the request with nil.
    nonisolated static func submitBackgroundRefresh(at date: Date?) {
        guard let date else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundRefreshID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshID)
        request.earliestBeginDate = max(date, Date().addingTimeInterval(60))
        // Fails when Background App Refresh is off (or in the simulator); the
        // activity then advances only through its embedded pass list.
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated private static func handleBackgroundRefresh(_ task: BGTask) {
        let completion = BackgroundTaskCompletion(task)
        let work = Task.detached(priority: .utility) { await backgroundRefresh() }
        task.expirationHandler = {
            work.cancel()
            completion.finish(success: false)
        }
        Task.detached {
            let success = await work.value
            completion.finish(success: success)
        }
    }

    /// Update (or end) the running activity from the background and request the
    /// next refresh. Activities can't be started from here, only updated or ended.
    nonisolated private static func backgroundRefresh() async -> Bool {
        if await MainActor.run(body: { FactoryResetService.didReset }) { return true }
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            _ = await apply(nil, canStart: false, manageScheduled: false)
            return true
        }
        let hasActivity = Activity<OrbitDeckPassAttributes>.activities.contains {
            $0.activityState != .ended && $0.activityState != .dismissed
        }
        guard hasActivity else { return true }
        let live = await MainActor.run { shared?.liveInputs() }
        guard let inputs = live ?? loadSavedInputs() else { return false }
        let plan = compute(inputs, now: Date())
        guard !Task.isCancelled else { return false }
        let wake = await apply(plan, canStart: false, manageScheduled: false)
        guard !Task.isCancelled else { return false }
        submitBackgroundRefresh(at: wake)
        return true
    }
}

/// Calls setTaskCompleted exactly once, whichever of the work or the expiration
/// handler gets there first. BGTask is safe to complete from any thread.
private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false

    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { task.setTaskCompleted(success: success) }
    }
}
#endif
