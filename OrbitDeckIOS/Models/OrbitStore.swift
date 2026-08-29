import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(Security)
import Security
#endif

@MainActor
final class OrbitStore: ObservableObject {
    @Published var satellites: [SatelliteRecord] = []
    @Published var preferences = StorePreferences() {
        didSet {
            savePreferences()
            ODFormat.useLocalTime = preferences.useLocalTime ?? false
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
    /// ban. Timestamps are per-dataset and persisted so the limit is honoured
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
        let extraIDs = (preferences.extraSatellites ?? []).map(\.norad)
        // fetchExtraNorads always queries CelesTrak (individual CATNR lookups).
        let allowedAtStart = celestrakAllowed("gp")

        // Honour CelesTrak's ≤1-request-per-2-hours policy when it is the source.
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
                if !refreshedExtras.isEmpty {
                    var byID = Dictionary(uniqueKeysWithValues: (preferences.extraSatellites ?? []).map { ($0.norad, $0) })
                    for record in refreshedExtras { byID[record.id] = ManualSatelliteDefinition(record: record) }
                    preferences.extraSatellites = byID.values.sorted { $0.norad < $1.norad }
                }
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
            let fetched = try await TransponderService.fetchAll()
            var byString: [String: [TransponderRecord]] = [:]
            for (norad, list) in fetched { byString[String(norad)] = list }
            allTransponders = byString
            try? Self.ensureApplicationSupport()
            if let data = try? JSONEncoder().encode(byString) {
                try? data.write(to: Self.transpondersCacheURL, options: [.atomic])
            }
            satellites = satellites.map { applyManualTransponders(to: $0) }
            lastTransponderRefresh = .now
            statusMessage = "Cached transmitters for \(byString.count) satellites"
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

    func addExtraSatellite(_ record: SatelliteRecord, transponders: [TransponderRecord]) {
        var extras = preferences.extraSatellites ?? []
        let definition = ManualSatelliteDefinition(record: record)
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
        let cached = allTransponders[key] ?? []
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
            if $0.isTwoWay != $1.isTwoWay { return $0.isTwoWay }
            return $0.description.localizedCaseInsensitiveCompare($1.description) == .orderedAscending
        }
    }

    private func loadPreferences() {
        guard let data = defaults.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode(StorePreferences.self, from: data) else {
            return
        }
        preferences = decoded
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
