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

    /// Element sets the operator imported, persisted in `importedElementsURL` and
    /// merged over the downloaded feed while their epoch is newer (see
    /// `ImportedElementSet.resolve`). Published for the "Imported Elements" list.
    @Published private(set) var importedElements: [ImportedElementSet] = []
    /// The last downloaded (or cached) GP feed plus refreshed extras, before the
    /// local layers are merged, so imports can be re-applied or removed without
    /// another download.
    private var feedRecords: [SatelliteRecord] = []

    private let defaults = UserDefaults.standard
    private let prefsKey = OrbitStore.preferencesKey
    nonisolated static let preferencesKey = "OrbitDeckIOS.preferences.v1"
    /// CelesTrak asks clients not to re-request the same data more than once every
    /// two hours (their GP updates no faster than that); exceeding it risks an IP
    /// ban. Timestamps are per-dataset and persisted so the limit is honored
    /// across app launches. Keys: `celestrakCooldownKey(for:)` (the chosen group,
    /// or the override URL), "extras" (per-NORAD lookups for new-launch extras),
    /// "newlaunch" (last-30-days scan) and "debris-<id>". The policy is about
    /// re-downloading the SAME data, so switching to a different group fetches it
    /// right away while re-fetching the same group still waits. (The pre-0.9.8
    /// single "gp" key is simply no longer read.)
    static let celestrakMinInterval: TimeInterval = 2 * 3600
    static let celestrakExtrasKey = "extras"
    /// Set on an HTTP 403/429: CelesTrak's limit is per client IP, so a rate limit
    /// blocks every GP dataset for a full window, not just the one that tripped it.
    static let celestrakRateLimitKey = "ratelimit"

    /// The cooldown key for the GP source a refresh would hit: the group ID, or a
    /// stable hash of the override URL (Swift's `hashValue` is per-launch seeded,
    /// so use FNV-1a to stay stable across launches).
    nonisolated static func celestrakCooldownKey(for preferences: StorePreferences) -> String {
        if let override = preferences.celestrakURLOverride?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in override.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return "url-" + String(hash, radix: 16)
        }
        return "group-" + preferences.celestrakGroup
    }

    private func celestrakLastFetch(_ key: String) -> Date? {
        let t = defaults.double(forKey: "OrbitDeckIOS.celestrak.\(key)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    func recordCelestrakFetch(_ key: String) {
        defaults.set(Date().timeIntervalSince1970, forKey: "OrbitDeckIOS.celestrak.\(key)")
    }
    /// True when enough time has elapsed to politely query the given CelesTrak dataset.
    func celestrakAllowed(_ key: String) -> Bool {
        guard let last = celestrakLastFetch(key) else { return true }
        return Date().timeIntervalSince(last) >= Self.celestrakMinInterval
    }
    /// Whole minutes until the next request for the given dataset is allowed.
    func celestrakCooldownMinutes(_ key: String) -> Int {
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

        loadImportedElements()

        if let cached = try? Data(contentsOf: Self.gpCacheURL),
           let records = try? GPService.parse(data: cached),
           !records.isEmpty {
            feedRecords = records
            satellites = mergeLocalCatalog(records)
            normalizeSelection()
            statusMessage = "Loaded cached GP catalog (\(records.count) objects)"
        } else if !importedElements.isEmpty {
            // No feed cached yet: still show imports (and custom satellites).
            satellites = mergeLocalCatalog([])
            normalizeSelection()
        }

        if feedRecords.isEmpty || (catalogAgeDays ?? .infinity) > 1.0 {
            await refreshGP()
        }
        await refreshAllTranspondersIfNeeded()
        await refreshSpaceWeatherIfNeeded()
    }

    /// Auto-refresh the catalogs on at least a weekly cadence: GP when the loaded
    /// elements are more than a day old (also covering the weekly floor), and the
    /// SatNOGS transmitter database once per week.
    func refreshCatalogsIfNeeded() async {
        if feedRecords.isEmpty || (catalogAgeDays ?? .infinity) > 1.0 { await refreshGP() }
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
        // fetchExtraNorads always queries CelesTrak (individual CATNR lookups), so
        // it has its own cooldown key, independent of the GP source's.
        let gpKey = Self.celestrakCooldownKey(for: preferences)
        let extrasAllowed = celestrakAllowed(Self.celestrakExtrasKey)

        // Honor CelesTrak's ≤1-request-per-2-hours policy for this same dataset.
        if usingCelestrak && !celestrakAllowed(gpKey) && !satellites.isEmpty {
            statusMessage = "Using cached elements — CelesTrak permits one update of this group every 2 hours (try again in ~\(celestrakCooldownMinutes(gpKey)) min)."
            return
        }
        if usingCelestrak && !celestrakAllowed(Self.celestrakRateLimitKey) {
            statusMessage = "Using cached elements — CelesTrak rate-limited this device; try again in ~\(celestrakCooldownMinutes(Self.celestrakRateLimitKey)) min."
            return
        }

        do {
            let result = try await GPService.fetch(preferences: preferences)
            if usingCelestrak { recordCelestrakFetch(gpKey) }

            var refreshedExtras: [SatelliteRecord] = []
            if !extraIDs.isEmpty && extrasAllowed {
                refreshedExtras = await GPService.fetchExtraNorads(extraIDs)
                recordCelestrakFetch(Self.celestrakExtrasKey)
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
            feedRecords = downloaded
            satellites = mergeLocalCatalog(mergeTransponders(old: satellites, new: downloaded))
            try Self.ensureApplicationSupport()
            try result.rawData.write(to: Self.gpCacheURL, options: [.atomic])
            lastGPRefresh = .now
            normalizeSelection()
            statusMessage = "GP updated: \(satellites.count) objects"
                + (result.skipped > 0 ? " (\(result.skipped) malformed record\(result.skipped == 1 ? "" : "s") skipped)" : "")
        } catch {
            // A CelesTrak 403/429 means we're being rate-limited; back off a full
            // window so we never escalate toward an IP ban.
            if usingCelestrak, case GPServiceError.badResponse(let code) = error, code == 403 || code == 429 {
                recordCelestrakFetch(gpKey)
                recordCelestrakFetch(Self.celestrakRateLimitKey)
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

    /// Import OMM/TLE text. Imports persist in an on-disk overlay that wins over
    /// the downloaded feed only while its epoch is newer. An import for a NORAD ID
    /// that is a manual satellite updates that manual definition's elements
    /// instead (keeping its name), since manual definitions always take precedence
    /// and an overlay entry would otherwise be silently shadowed.
    func importTLEText(_ text: String) {
        let parsed = GPService.parseElementTextCounting(text)
        let imported = parsed.records
        let skippedNote = parsed.skipped > 0 ? " (\(parsed.skipped) malformed entr\(parsed.skipped == 1 ? "y" : "ies") skipped)" : ""
        guard !imported.isEmpty else {
            lastError = "No usable elements were found\(skippedNote). Supported formats: OMM (JSON, XML, or CSV) and classic TLE."
            return
        }

        var manual = preferences.manualSatellites ?? []
        var overlay = Dictionary(importedElements.map { ($0.norad, $0) }, uniquingKeysWith: { _, b in b })
        var updatedManual = 0
        for record in imported {
            if let index = manual.firstIndex(where: { $0.norad == record.id }) {
                var definition = ManualSatelliteDefinition(record: record)
                definition.name = manual[index].name
                manual[index] = definition
                updatedManual += 1
            } else {
                overlay[record.id] = ImportedElementSet(record: record)
            }
        }
        if updatedManual > 0 { preferences.manualSatellites = manual }
        importedElements = overlay.values.sorted { $0.norad < $1.norad }
        rebuildCatalog()
        // Entries no newer than the feed were pruned by the merge.
        let kept = imported.filter { record in importedElements.contains { $0.norad == record.id } }.count
        let older = imported.count - kept - updatedManual
        saveImportedElements()
        normalizeSelection()
        var message = "Imported \(imported.count) element set\(imported.count == 1 ? "" : "s")"
        if updatedManual > 0 { message += ", updated \(updatedManual) manual satellite\(updatedManual == 1 ? "" : "s")" }
        if older > 0 { message += ", \(older) not newer than the downloaded elements (ignored)" }
        statusMessage = message + skippedNote
    }

    /// Remove imported element sets; the downloaded elements (if any) take over.
    func removeImportedElements(_ norads: Set<UInt>) {
        importedElements.removeAll { norads.contains($0.norad) }
        saveImportedElements()
        rebuildCatalog(dropping: norads)
        normalizeSelection()
        statusMessage = "Removed \(norads.count) imported element set\(norads.count == 1 ? "" : "s")"
    }

    /// Re-merge the local layers over `feedRecords` without a download. Records
    /// that no source owns (e.g. a CelesTrak search hit added this session) are
    /// kept, except the IDs in `dropping` (an overlay entry just removed).
    private func rebuildCatalog(dropping: Set<UInt> = []) {
        var owned = Set(feedRecords.map(\.id))
        owned.formUnion(importedElements.map(\.norad))
        owned.formUnion((preferences.extraSatellites ?? []).map(\.norad))
        owned.formUnion((preferences.manualSatellites ?? []).map(\.norad))
        let sessionOnly = satellites.filter { !owned.contains($0.id) && !dropping.contains($0.id) }
        satellites = mergeLocalCatalog(mergeTransponders(old: satellites, new: feedRecords) + sessionOnly)
    }

    private func loadImportedElements() {
        guard let data = try? Data(contentsOf: Self.importedElementsURL),
              let entries = try? JSONDecoder().decode([ImportedElementSet].self, from: data) else { return }
        importedElements = entries
    }

    private func saveImportedElements() {
        try? Self.ensureApplicationSupport()
        if importedElements.isEmpty {
            try? FileManager.default.removeItem(at: Self.importedElementsURL)
        } else if let data = try? JSONEncoder().encode(importedElements) {
            try? data.write(to: Self.importedElementsURL, options: [.atomic])
        }
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
        // Imports go over the feed only while newer; superseded entries are pruned
        // from the overlay (the feed has caught up), keeping its file small.
        let resolved = ImportedElementSet.resolve(importedElements, feedEpochs: map.mapValues(\.epoch))
        for entry in resolved.active {
            var record = entry.record
            if let feed = map[entry.norad] {
                // Keep the feed's (often amateur) name and any loaded transmitters.
                record.name = feed.name
                record.transponders = feed.transponders
            }
            map[entry.norad] = applyManualTransponders(to: record)
        }
        if !resolved.superseded.isEmpty {
            importedElements = resolved.active
            saveImportedElements()
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

    /// The imported-elements overlay (see `ImportedElementSet`).
    nonisolated static var importedElementsURL: URL {
        applicationSupportURL.appendingPathComponent("imported-elements.json")
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
        if let data = try? Data(contentsOf: importedElementsURL),
           let overlay = try? JSONDecoder().decode([ImportedElementSet].self, from: data) {
            let relevant = overlay.filter { ids.contains($0.norad) }
            for entry in ImportedElementSet.resolve(relevant, feedEpochs: map.mapValues(\.epoch)).active {
                var record = entry.record
                if let feed = map[entry.norad] { record.name = feed.name }
                map[entry.norad] = record
            }
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

    /// When the app started this activity (nil for activities from builds before
    /// 1.1 (4)). Lets the app replace an old one before iOS's 8-hour limit ends it.
    var startedAt: Date? = nil

    /// One pass in the embedded look-ahead list. Short coding keys keep the
    /// content well under the 4 KB ActivityKit limit; fields added later are
    /// optional so content from older builds still decodes.
    struct Pass: Codable, Hashable {
        var satellite: String
        var aos: Date
        var los: Date
        var maxElevation: Double
        /// When auto switching selects this satellite (can precede AOS).
        var switchAt: Date?
        /// Azimuths at AOS and LOS in degrees (nil before 1.1 (4)).
        var aosAzimuth: Double? = nil
        var losAzimuth: Double? = nil
        /// NORAD catalog number, for the tap-to-open link (nil in older content).
        var norad: UInt? = nil

        enum CodingKeys: String, CodingKey {
            case satellite = "n", aos = "a", los = "l", maxElevation = "e", switchAt = "s"
            case aosAzimuth = "aa", losAzimuth = "la", norad = "i"
        }

        /// When this pass becomes the one to show: the switch time, else AOS.
        var start: Date { switchAt ?? aos }
    }

    /// Tapping the activity opens `orbitdeck://satellite/<NORAD ID>`, which selects
    /// that satellite (the scheme is registered in the app's Info.plist).
    static let urlScheme = "orbitdeck"

    static func url(norad: UInt?) -> URL? {
        guard let norad, norad > 0 else { return nil }
        return URL(string: "\(urlScheme)://satellite/\(norad)")
    }

    /// The NORAD ID in a link made by `url(norad:)`; nil for anything else.
    static func norad(from url: URL) -> UInt? {
        guard url.scheme?.lowercased() == urlScheme, url.host()?.lowercased() == "satellite",
              url.query() == nil, url.fragment() == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let digits = parts.first, digits.count <= 9,
              digits.allSatisfy({ ("0"..."9").contains($0) }),
              let norad = UInt(digits), norad > 0 else { return nil }
        return norad
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
            if let passes, !passes.isEmpty { return passes.sorted { $0.start < $1.start } }
            return [Pass(satellite: satellite, aos: aos, los: los, maxElevation: maxElevation, switchAt: switchAt)]
        }

        /// The pass to show at `date`, nil once every pass has ended. Among passes
        /// already started (switched in, or past AOS) and not yet set: with auto
        /// switching the latest switch wins, as the switcher would have moved on to
        /// it; for favorites the earliest stays until its LOS, so a pass being
        /// worked isn't replaced by one rising later. Otherwise the next to start.
        func pass(at date: Date) -> Pass? {
            let live = timeline.filter { $0.los > date }
            let started = live.filter { $0.start <= date }
            if let current = source == .priority ? started.last : started.first {
                return current
            }
            return live.first
        }

        /// The pass after `pass` in the list (the next one to start), for "Then …".
        func following(_ pass: Pass) -> Pass? {
            let list = timeline
            guard let index = list.firstIndex(of: pass), index + 1 < list.count else { return nil }
            return list[index + 1]
        }

        /// The first moment after `date` at which `pass(at:)` gives a different
        /// pass (or nil, once the last has ended); nil when it never changes again.
        /// iOS redraws a Live Activity it isn't updating once, at the stale date, and
        /// every layout reads right through AOS without a redraw, so that one redraw
        /// is spent here, where it moves the activity on to the next pass.
        func passChange(after date: Date) -> Date? {
            let shown = pass(at: date)
            guard shown != nil else { return nil }
            let moments = Set(timeline.flatMap { [$0.start, $0.los] }).filter { $0 > date }.sorted()
            return moments.first { pass(at: $0) != shown }
        }

        /// The next switch, AOS or LOS after `date`, when anything shown changes.
        func nextTransition(after date: Date) -> Date? {
            timeline.flatMap { [$0.switchAt, $0.aos, $0.los].compactMap { $0 } }
                .filter { $0 > date }
                .min()
        }
    }
}

/// Keeps one Live Activity showing the next pass.
///
/// Which satellite it follows (the rule; Settings and Help say the same):
/// - Auto switching on with a priority list: the priority satellite selected now
///   while its pass is up, then each satellite the switcher will switch to, with
///   the switch time. Changing the selection or the priorities replans it.
/// - Otherwise: the next passes of the favorites above the pass-prediction minimum
///   (the selected satellite when there are no favorites). The selection otherwise
///   doesn't change it.
///
/// While OrbitDeck isn't running iOS gives it no time, so the content carries the
/// next few passes and the widget draws everything from dates: the countdown to
/// AOS, then the pass-left timer and progress bar run by themselves through the
/// pass. The stale date is the LOS (or the next switch), when iOS redraws the
/// activity once more and the widget moves on to the next pass from the list.
/// Beyond that it stays current through a background app refresh (at iOS's
/// discretion) and, opt-in on iOS 26+, a scheduled activity for a later pass
/// that iOS starts by itself. There is never more than one running activity:
/// refreshes are serialized, extras are ended, and dead ones are cleared.
@MainActor
final class LiveActivityController: ObservableObject {
    nonisolated static let enabledKey = "liveActivityEnabled"
    /// Opt-in (iOS 26+): schedule an activity for a later pass that the system
    /// starts on its own, with an alert, even while OrbitDeck is closed.
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
    /// iOS ends a Live Activity after 8 hours. One older than this is replaced with
    /// a fresh one when the app is opened (outside a pass), so it lasts the night.
    nonisolated static let replaceAge: TimeInterval = 4 * 3600
    nonisolated static let logCategory = "liveactivity"

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
        /// The candidates: the priority list (in order), else the favorites (else
        /// the selected satellite).
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
        /// A later pass, for the opt-in scheduled activity.
        var scheduled: OrbitDeckPassAttributes.ContentState?
        /// When the scheduled activity starts: `scheduledLead` before its pass, but
        /// not before the running activity's last reachable pass has set, so it
        /// doesn't take the Dynamic Island (higher relevance) during that pass.
        var scheduledStart: Date? = nil
    }

    /// The attached controller, so a background refresh in a running app goes
    /// through it (serialized, with its loaded catalog) instead of reading from disk.
    private static weak var shared: LiveActivityController?

    private weak var store: OrbitStore?
    private weak var autoSwitch: AutoSwitchController?
    private var loop: Task<Void, Never>?
    /// One refresh at a time: overlapping ones (the loop, the app coming forward,
    /// a setting) could otherwise both see no activity and start two, or one could
    /// end the activity with a plan the other hasn't computed yet.
    private var refreshing = false
    private var refreshAgain = false
    private var lastKey = ""
    private var computedAt = Date.distantPast
    private var plan: Plan?
    private var loggedDisabled = false
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

    /// Attached with the catalog loaded (else a background refresh plans from disk).
    fileprivate var isReady: Bool { store.map { !$0.satellites.isEmpty } ?? false }

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

    /// Recompute when the inputs change, a transition passes, or every 10 minutes;
    /// then start, update or end the activity to match. Serialized: a call made
    /// while one is running makes that one go round again instead.
    func refresh(now: Date = .now) async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        var date = now
        repeat {
            refreshAgain = false
            await refreshOnce(now: date)
            date = .now
        } while refreshAgain
    }

    private func refreshOnce(now: Date) async {
        guard let store, let autoSwitch, !FactoryResetService.didReset else { return }
        let foreground = UIApplication.shared.applicationState == .active
        let authorized = ActivityAuthorizationInfo().areActivitiesEnabled
        guard Self.isEnabled, authorized else {
            if !loggedDisabled {
                loggedDisabled = true
                ODLog.shared.log(Self.isEnabled ? "Live Activities are off in iOS Settings for OrbitDeck"
                                                : "Live Activity turned off in OrbitDeck Settings",
                                 category: Self.logCategory)
            }
            plan = nil; lastKey = ""
            _ = await Self.apply(nil, canStart: false, manageScheduled: true)
            setWake(nil, foreground: foreground)
            return
        }
        loggedDisabled = false
        // Catalog not loaded yet: an empty plan would end the activity a previous
        // run left, only to start it again a moment later.
        guard !store.satellites.isEmpty else { return }
        let inputs = Self.inputs(store: store, autoSwitch: autoSwitch)
        let next = inputs.usePriorities ? autoSwitch.nextSwitch : nil
        let ids = inputs.records.map(\.id)
        let key = "\(inputs.usePriorities)|\(ids)|\(inputs.observer.stableKey)|\(inputs.minElevation)|\(inputs.preemption.rawValue)|\(inputs.preemptElevation)|\(inputs.selected ?? 0)|\(next?.norad ?? 0)|\(next?.date.timeIntervalSince1970 ?? 0)|\(store.satellites.count)|\(inputs.utc)|\(Self.elementsFingerprint(inputs.records.map(\.epoch)))"
        let expired = plan?.current?.nextTransition(after: computedAt).map { $0 <= now } ?? false
        if plan == nil || key != lastKey || expired || now.timeIntervalSince(computedAt) > 600 {
            lastKey = key; computedAt = now
            // The passes already shown, so recomputing (whose switch times move by
            // up to a 30 s planning step) doesn't push a needless update.
            let previous = plan.map { ($0.current?.passes ?? []) + ($0.scheduled?.passes ?? []) }
                ?? Self.runningTimeline()
            plan = await Task.detached(priority: .utility) {
                Self.compute(inputs, now: now, previous: previous)
            }.value
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
        let ids = candidateIDs(usePriorities: usePriorities, priorities: settings.priorities,
                               favorites: store.preferences.favorites, selected: store.preferences.selectedNorad)
        return Inputs(records: ids.compactMap { id in store.satellites.first { $0.id == id } },
                      usePriorities: usePriorities, observer: store.preferences.observer,
                      minElevation: usePriorities ? autoSwitch.threshold(for: store) : store.preferences.minElevation,
                      preemption: settings.preemption, preemptElevation: settings.preemptElevation,
                      selected: store.preferences.selectedNorad, utc: !ODFormat.useLocalTime)
    }

    /// The priority list (in order) with auto switching, else the favorites, else
    /// the selected satellite.
    nonisolated static func candidateIDs(usePriorities: Bool, priorities: [UInt], favorites: Set<UInt>,
                                         selected: UInt?) -> [UInt] {
        if usePriorities { return priorities }
        if !favorites.isEmpty { return favorites.sorted() }
        return selected.map { [$0] } ?? []
    }

    /// Changes whenever a candidate's element set does (a catalog refresh or TLE
    /// import with a newer epoch), so the plan is recomputed right away instead of
    /// at the 10-minute recompute.
    nonisolated static func elementsFingerprint(_ epochs: [Date]) -> String {
        let seconds = epochs.map(\.timeIntervalSince1970)
        return "\(seconds.count):\(seconds.max() ?? 0):\(seconds.reduce(0, +))"
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
        let ids = candidateIDs(usePriorities: usePriorities, priorities: settings.priorities,
                               favorites: preferences.favorites, selected: preferences.selectedNorad)
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

    /// The passes in the running activity's content (to keep them stable when the
    /// app plans again after a relaunch).
    nonisolated static func runningTimeline() -> [OrbitDeckPassAttributes.Pass] {
        Activity<OrbitDeckPassAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .flatMap { $0.content.state.timeline }
    }

    /// Reuse a pass from `previous` when the new plan has the same one, so planning
    /// jitter (switch times move by up to a 30 s step, AOS/LOS by seconds) doesn't
    /// change the content: no update, no redraw, no "14:04Z" ↔ "14:05Z" flicker.
    nonisolated static func stabilized(_ list: [OrbitDeckPassAttributes.Pass],
                                       previous: [OrbitDeckPassAttributes.Pass]) -> [OrbitDeckPassAttributes.Pass] {
        func close(_ a: Date?, _ b: Date?, _ tolerance: TimeInterval) -> Bool {
            switch (a, b) {
            case (nil, nil): true
            case let (a?, b?): abs(a.timeIntervalSince(b)) <= tolerance
            default: false
            }
        }
        return list.map { item in
            guard let old = previous.first(where: {
                $0.satellite == item.satellite && close($0.aos, item.aos, 30) && close($0.los, item.los, 30)
                    && close($0.switchAt, item.switchAt, 60) && abs($0.maxElevation - item.maxElevation) < 1
            }) else { return item }
            // Content from an older build lacks the azimuths or the NORAD ID: take the new pass.
            let upgraded = (old.aosAzimuth == nil && item.aosAzimuth != nil) || (old.norad == nil && item.norad != nil)
            return upgraded ? item : old
        }
    }

    /// CPU-bound (SGP4): call from a detached task.
    nonisolated static func compute(_ inputs: Inputs, now: Date,
                                    previous: [OrbitDeckPassAttributes.Pass] = []) -> Plan {
        typealias Pass = OrbitDeckPassAttributes.Pass
        // Spares, so the scheduled activity also gets a full list.
        let wanted = embeddedPassCount + 3
        func entry(_ record: SatelliteRecord, _ pass: PredictedPass, switchAt: Date?) -> Pass {
            Pass(satellite: String(record.name.prefix(40)), aos: pass.aos, los: pass.los,
                 maxElevation: (pass.maxElevation * 10).rounded() / 10, switchAt: switchAt,
                 aosAzimuth: pass.aosAzimuth.rounded(), losAzimuth: pass.losAzimuth.rounded(), norad: record.id)
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
                                                               minElevation: inputs.minElevation, maxCount: 4,
                                                               horizonDays: 2)) ?? []
                all += found.filter { $0.duration < 12 * 3600 && $0.los > now }
                    .map { entry(record, $0, switchAt: nil) }
            }
            for item in all.sorted(by: { $0.aos < $1.aos }) where list.count < wanted {
                if !list.contains(where: { samePass($0, item) }) { list.append(item) }
            }
        }
        list = stabilized(list, previous: previous).sorted { $0.start < $1.start }
        return makePlan(from: list, source: inputs.usePriorities ? .priority : .favorite, utc: inputs.utc, now: now)
    }

    /// The running and scheduled contents for a planned pass list (sorted by start).
    nonisolated static func makePlan(from list: [OrbitDeckPassAttributes.Pass], source: OrbitDeckPassAttributes.Source,
                                 utc: Bool, now: Date) -> Plan {
        typealias Pass = OrbitDeckPassAttributes.Pass
        func state(_ passes: [Pass], at date: Date) -> OrbitDeckPassAttributes.ContentState? {
            guard let first = passes.first else { return nil }
            let probe = OrbitDeckPassAttributes.ContentState(
                satellite: first.satellite, aos: first.aos, los: first.los, maxElevation: first.maxElevation,
                switchAt: first.switchAt, source: source, inPass: false, utc: utc, passes: passes)
            guard let shown = probe.pass(at: date) else { return nil }
            return OrbitDeckPassAttributes.ContentState(
                satellite: shown.satellite, aos: shown.aos, los: shown.los, maxElevation: shown.maxElevation,
                switchAt: shown.switchAt, source: source, inPass: shown.aos <= date, utc: utc,
                passes: passes)
        }
        let current = state(Array(list.prefix(embeddedPassCount)), at: now)
        // Without the app the running activity reaches the pass shown now and, after
        // its one redraw at the stale date, the next. Schedule the pass after that.
        var scheduled: OrbitDeckPassAttributes.ContentState?
        var scheduledStart: Date?
        if let current, let shown = current.pass(at: now) {
            let reach = current.passChange(after: now).flatMap { current.pass(at: $0) } ?? shown
            if let index = list.firstIndex(of: reach), index + 1 < list.count {
                let following = Array(list[(index + 1)...].prefix(embeddedPassCount))
                if let first = following.first {
                    // Not before the reachable pass sets: the scheduled activity has
                    // the higher relevance and would take the island mid-pass. If that
                    // pass outlasts this one, the running activity covers it anyway.
                    let start = max(first.start.addingTimeInterval(-scheduledLead), reach.los)
                    if start < first.los.addingTimeInterval(-60) {
                        scheduled = state(following, at: first.start)
                        scheduledStart = start
                    }
                }
            }
        }
        return Plan(current: current, scheduled: scheduled, scheduledStart: scheduled == nil ? nil : scheduledStart)
    }

    /// When the background refresh should run for `state`: the shown pass's AOS if
    /// that comes first, else the stale date. An update at AOS (inPass flips) redraws
    /// the activity with the LOS countdown without spending the stale-date redraw.
    nonisolated static func backgroundWake(for state: OrbitDeckPassAttributes.ContentState, staleDate: Date,
                                           now: Date) -> Date {
        guard let aos = state.pass(at: now)?.aos, aos > now else { return staleDate }
        return min(aos, staleDate)
    }

    /// Start, update or end the running activity to match `plan`, and (from the
    /// foreground) reconcile the scheduled one. Returns when a background refresh
    /// should next run: the shown pass's AOS or the stale date, whichever is first
    /// (or nil with nothing to keep current).
    /// Nonisolated so the (non-Sendable) Activity objects never cross actors.
    nonisolated private static func apply(_ plan: Plan?, canStart: Bool, manageScheduled: Bool) async -> Date? {
        let now = Date()
        let all = Activity<OrbitDeckPassAttributes>.activities
        // Ended by iOS's time limit (or an earlier run) but still on the Lock Screen:
        // dismiss them, so a dead activity doesn't sit next to (or instead of) the live one.
        for activity in all where activity.activityState == .ended {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        // A scheduled activity that has started has the higher relevance; keep it
        // and end the older one it replaces.
        let running = all.filter { $0.activityState == .active || $0.activityState == .stale }
            .sorted { $0.content.relevanceScore > $1.content.relevanceScore }
        var wake: Date?
        if let state = plan?.current {
            // Every layout reads right through AOS by itself, so the one redraw iOS
            // gives an activity it isn't updating (at the stale date) is spent where
            // it must show a different pass. A stale date at AOS would spend it there
            // and leave the activity stuck on that pass (see passChange(after:)).
            let staleDate = state.passChange(after: now) ?? state.los
            let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: currentRelevance)
            let inPass = state.pass(at: now).map { $0.aos <= now } ?? false
            let keep = running.first.flatMap { activity -> Activity<OrbitDeckPassAttributes>? in
                let age = activity.attributes.startedAt.map { now.timeIntervalSince($0) } ?? .infinity
                return canStart && !inPass && age > replaceAge ? nil : activity
            }
            if let activity = keep {
                for extra in running where extra.id != activity.id {
                    ODLog.shared.log("Ending duplicate activity \(extra.id)", category: logCategory)
                    await extra.end(nil, dismissalPolicy: .immediate)
                }
                if activity.content.state != state || activity.content.staleDate != staleDate
                    || activity.content.relevanceScore != currentRelevance || activity.activityState == .stale {
                    await activity.update(content)
                }
            } else if canStart {
                do {
                    let activity = try Activity.request(attributes: OrbitDeckPassAttributes(startedAt: now),
                                                        content: content, pushType: nil)
                    ODLog.shared.log("Started \(activity.id): \(state.satellite) AOS \(state.aos), stale \(staleDate)"
                                     + (running.isEmpty ? "" : ", replacing \(running.count) older"),
                                     category: logCategory)
                    for old in running { await old.end(nil, dismissalPolicy: .immediate) }
                } catch {
                    ODLog.shared.log("Start failed: \(error)", category: logCategory)
                    // Replacement failed: keep the old one current instead.
                    if let activity = running.first { await activity.update(content) }
                }
            }
            wake = backgroundWake(for: state, staleDate: staleDate, now: now)
        } else {
            for activity in running {
                ODLog.shared.log("Ending \(activity.id): no planned pass", category: logCategory)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        if #available(iOS 26.0, *) {
            var pending = all.filter { $0.activityState == .pending }
            if manageScheduled {
                let wanted = isEnabled && scheduleNextEnabled ? plan?.scheduled : nil
                pending = await reconcileScheduled(wanted, start: plan?.scheduledStart, pending: pending, now: now)
            }
            // Wake shortly after a scheduled activity starts, to fold it together
            // with the running one.
            for activity in pending {
                // startedAt is the scheduled start (older ones: the lead before the pass).
                let start = (activity.attributes.startedAt
                             ?? activity.content.state.timeline.first?.start.addingTimeInterval(-scheduledLead))?
                    .addingTimeInterval(60)
                if let start, start > now { wake = min(wake ?? start, start) }
            }
        }
        return wake
    }

    /// Keep at most one pending activity, for `wanted`'s first pass; replace it when
    /// the plan changes. Returns the pending activities left.
    @available(iOS 26.0, *)
    nonisolated private static func reconcileScheduled(_ wanted: OrbitDeckPassAttributes.ContentState?,
                                                       start plannedStart: Date?,
                                                       pending: [Activity<OrbitDeckPassAttributes>],
                                                       now: Date) async -> [Activity<OrbitDeckPassAttributes>] {
        guard let wanted, let pass = wanted.timeline.first,
              case let start = plannedStart ?? pass.start.addingTimeInterval(-scheduledLead),
              start > now.addingTimeInterval(60) else {
            // Nothing to schedule, or it's due so soon the running activity covers it.
            for activity in pending { await activity.end(nil, dismissalPolicy: .immediate) }
            return []
        }
        if let match = pending.first(where: { activity in
            let sameStart = activity.attributes.startedAt.map { abs($0.timeIntervalSince(start)) < 60 } ?? true
            return sameStart && activity.content.state.timeline.first.map {
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
        let title = minutes > 0 ? "\(name) pass in \(minutes) min" : "\(name) pass now"
        var body = "AOS \(clock(pass.aos, utc: wanted.utc)), max \(Int(pass.maxElevation.rounded()))°"
        if let switchAt = pass.switchAt { body += ", auto switch at \(clock(switchAt, utc: wanted.utc))" }
        let alert = AlertConfiguration(title: LocalizedStringResource(String.LocalizationValue(title)),
                                       body: LocalizedStringResource(String.LocalizationValue(body)),
                                       sound: .default)
        let content = ActivityContent(state: wanted, staleDate: wanted.passChange(after: start) ?? pass.los,
                                      relevanceScore: scheduledRelevance)
        do {
            let activity = try Activity.request(attributes: OrbitDeckPassAttributes(startedAt: start), content: content,
                                                pushType: nil, style: .standard,
                                                alertConfiguration: alert, start: start)
            ODLog.shared.log("Scheduled \(activity.id): \(pass.satellite) starts \(start)", category: logCategory)
            return [activity]
        } catch {
            // Too many Live Activities at once (OrbitDeck's or the system's), or not
            // allowed: skip the reminder; the running activity still lists this
            // pass. Retried when the plan changes or the app is next opened.
            ODLog.shared.log("Scheduling failed: \(error)", category: logCategory)
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
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            ODLog.shared.log("Background refresh not scheduled: \(error)", category: logCategory)
        }
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
        ODLog.shared.log("Background refresh", category: logCategory)
        // App already running (e.g. recording in the background): its serialized
        // refresh does the work and submits the next wake itself.
        if let controller = await MainActor.run(body: { shared.flatMap { $0.isReady ? $0 : nil } }) {
            await controller.refresh()
            return true
        }
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            _ = await apply(nil, canStart: false, manageScheduled: false)
            return true
        }
        let hasActivity = Activity<OrbitDeckPassAttributes>.activities.contains {
            $0.activityState != .ended && $0.activityState != .dismissed
        }
        guard hasActivity else { return true }
        guard let inputs = loadSavedInputs() else {
            submitBackgroundRefresh(at: Date().addingTimeInterval(3600))
            return false
        }
        let plan = compute(inputs, now: Date(), previous: runningTimeline())
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
