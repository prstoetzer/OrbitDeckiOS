import SwiftUI
import UIKit
import UserNotifications

/// Routes a tapped pass-reminder notification to the Home screen. Mirrors the
/// `@preconcurrency` delegate pattern used by LocationProvider; the notification
/// callbacks are delivered on the main thread.
@MainActor
final class NotificationRouter: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    @Published var openHomeRequested = false

    func activate() { UNUserNotificationCenter.current().delegate = self }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        openHomeRequested = true
        completionHandler()
    }
}

enum OrbitDestination: String, CaseIterable, Identifiable, Hashable {
    case home, track, globe, radar, gridfinder
    case passes, skyglance, schedule, passdetail, groundtrack, tenday
    case orbit, orbithistory, illum, zones, ao7, mutual, transits, astronomy, skymap, conjunction, grids
    case radio, log, sstv, planning, tools, graphcalc, tinybasic, datafeeds, amsatstatus, oscarsim, oscarref, learn, references, exports
    case sunmoon, celestial, eme, spacewx, muf, propagation
    case satellites, newlaunch, sites, calibrations, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .track: "Track"
        case .globe: "3D Globe"
        case .radar: "Sky Radar"
        case .gridfinder: "Grid Finder"
        case .passes: "Next Passes"
        case .skyglance: "Sky at a Glance"
        case .schedule: "Daily Schedule"
        case .passdetail: "Pass Detail"
        case .groundtrack: "Ground Track"
        case .tenday: "Pass Progression"
        case .orbit: "Orbital Analysis"
        case .orbithistory: "Orbital History"
        case .illum: "Illumination"
        case .zones: "Orbital Zones"
        case .ao7: "AO-7 Mode"
        case .mutual: "Mutual Windows"
        case .transits: "Sun/Moon Transits"
        case .astronomy: "Astronomy"
        case .skymap: "Sky Map"
        case .conjunction: "Conjunctions"
        case .grids: "Workable"
        case .radio: "Radio"
        case .log: "Log"
        case .sstv: "SSTV Images"
        case .planning: "Planning"
        case .tools: "Tools"
        case .graphcalc: "Graphing Calc"
        case .tinybasic: "Tiny BASIC"
        case .datafeeds: "Activations / QRZ"
        case .amsatstatus: "AMSAT Status"
        case .oscarsim: "OSCARLOCATOR Sim"
        case .oscarref: "OSCARLOCATOR Reference Orbits"
        case .learn: "Learn"
        case .references: "References"
        case .exports: "Exports"
        case .sunmoon: "Sun / Moon"
        case .celestial: "Celestial"
        case .eme: "EME"
        case .spacewx: "Space Wx"
        case .muf: "MUF / HF Prop"
        case .propagation: "Propagation"
        case .satellites: "Satellites"
        case .newlaunch: "New Launches"
        case .sites: "Sites"
        case .calibrations: "Calibrations"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .track: "scope"
        case .globe: "globe.americas"
        case .radar: "dot.radiowaves.left.and.right"
        case .gridfinder: "location.north.line.fill"
        case .passes: "clock.arrow.2.circlepath"
        case .skyglance: "sparkles"
        case .schedule: "calendar.badge.clock"
        case .passdetail: "chart.xyaxis.line"
        case .groundtrack: "map"
        case .tenday: "chart.line.uptrend.xyaxis"
        case .orbit: "circle.dashed.inset.filled"
        case .orbithistory: "clock.arrow.circlepath"
        case .illum: "sun.max"
        case .zones: "circle.grid.cross"
        case .ao7: "7.circle"
        case .mutual: "person.2.wave.2"
        case .transits: "sun.horizon"
        case .astronomy: "star"
        case .skymap: "sparkle.magnifyingglass"
        case .conjunction: "arrow.trianglehead.merge"
        case .grids: "square.grid.3x3"
        case .radio: "radio"
        case .log: "book.pages"
        case .sstv: "photo.on.rectangle.angled"
        case .planning: "calendar"
        case .tools: "wrench.and.screwdriver"
        case .graphcalc: "function"
        case .tinybasic: "terminal"
        case .datafeeds: "antenna.radiowaves.left.and.right"
        case .amsatstatus: "waveform.path.ecg"
        case .oscarsim: "scope"
        case .oscarref: "calendar.badge.clock"
        case .learn: "book"
        case .references: "books.vertical"
        case .exports: "square.and.arrow.up"
        case .sunmoon: "sun.and.horizon"
        case .celestial: "moon.stars"
        case .eme: "moon"
        case .spacewx: "sun.max.trianglebadge.exclamationmark"
        case .muf: "wave.3.right"
        case .propagation: "point.3.connected.trianglepath.dotted"
        case .satellites: "list.bullet"
        case .newlaunch: "airplane.departure"
        case .sites: "mappin.and.ellipse"
        case .calibrations: "tuningfork"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }

    /// Screens that don't act on the active satellite shouldn't show the global
    /// satellite switcher in their toolbar.
    var usesSelectedSatellite: Bool {
        switch self {
        case .radar, .gridfinder, .schedule, .sunmoon, .spacewx, .muf, .propagation, .tools, .graphcalc, .tinybasic,
             .datafeeds, .learn, .references, .newlaunch, .sites, .astronomy, .eme, .log, .sstv,
             .satellites, .calibrations, .settings, .about:
            return false
        default:
            return true
        }
    }

    var implemented: Bool {
        switch self {
        case .home, .track, .globe, .radar, .gridfinder, .passes, .skyglance, .schedule, .passdetail, .groundtrack, .tenday,
             .orbit, .orbithistory, .illum, .zones, .ao7, .mutual, .transits, .astronomy,
             .skymap, .conjunction, .grids,
             .radio, .log, .sstv, .planning, .tools, .graphcalc, .tinybasic, .datafeeds, .amsatstatus, .oscarsim, .oscarref, .learn, .references, .exports, .sunmoon, .celestial, .eme, .spacewx, .muf, .propagation,
             .satellites, .newlaunch, .sites, .calibrations, .settings, .about:
            true
        default:
            false
        }
    }
}

private struct NavGroup: Identifiable {
    let id: String
    let title: String
    let items: [OrbitDestination]
}

private let navGroups: [NavGroup] = [
    NavGroup(id: "live", title: "LIVE", items: [.home, .globe, .radar, .gridfinder]),
    NavGroup(id: "passes", title: "PASSES", items: [.passes, .skyglance, .schedule, .groundtrack, .tenday]),
    NavGroup(id: "analysis", title: "ANALYSIS", items: [.orbit, .orbithistory, .illum, .zones, .ao7, .mutual, .transits, .astronomy, .skymap, .conjunction, .grids]),
    NavGroup(id: "operating", title: "OPERATING TOOLS", items: [.radio, .log, .sstv, .planning, .tools, .graphcalc, .tinybasic, .datafeeds, .amsatstatus, .oscarsim, .oscarref, .learn, .references, .exports]),
    NavGroup(id: "sky", title: "SKY & SPACE", items: [.sunmoon, .celestial, .eme, .spacewx, .muf, .propagation]),
    NavGroup(id: "catalog", title: "CATALOG & CONFIGURATION", items: [.satellites, .newlaunch, .sites, .calibrations, .settings, .about])
]

struct RootView: View {
    @EnvironmentObject private var store: OrbitStore
    @EnvironmentObject private var notifications: NotificationRouter
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var autoLocation = LocationProvider()
    @State private var selection: OrbitDestination? = .home
    // The last non-nil selection. NavigationSplitView can briefly hand the detail
    // a nil selection while a heavy screen re-renders; falling back to `.home`
    // there made the detail flash the Home screen. Falling back to the last real
    // selection keeps the current screen on-screen through that transient.
    @State private var lastSelection: OrbitDestination = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    // When on, the device won't auto-lock while the Home screen is showing, so an
    // operator can leave it up as a live "shack clock" during a pass. iOS resets
    // the idle timer whenever the app backgrounds, so it's re-applied on foreground.
    @AppStorage("orbitdeck.keepScreenAwakeHome") private var keepScreenAwakeHome = false
    // Throttle how often a current-location fix is written into the observer, so
    // the live screens (which recompute against the observer) update at most once
    // per second rather than on every high-rate GPS fix.
    @State private var lastLocationApply = Date.distantPast

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                ForEach(navGroups) { group in
                    Section(group.title) {
                        ForEach(group.items) { destination in
                            Label(destination.title, systemImage: destination.icon)
                                .font(.body)
                                .tag(destination)
                        }
                    }
                }
                Section {
                    Text(refreshHelp).font(.caption).foregroundStyle(ODTheme.muted)
                } header: {
                    Text("UPDATING ELEMENTS")
                }
            }
            .navigationTitle("OrbitDeck")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isRefreshingGP {
                        ProgressView()
                    } else {
                        Button {
                            Task { await store.refreshGP() }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .accessibilityLabel("Update orbital elements")
                    }
                }
            }
        } detail: {
            // Resolve a nil selection to the last real screen rather than Home, so
            // a transient nil during a heavy re-render doesn't flash the Home view.
            let shown = selection ?? lastSelection
            destinationView(shown)
                // Cap reading-oriented screens at a comfortable width and center
                // them so cards/text don't stretch across a wide iPad detail pane.
                // Full-bleed visual screens (globe, radar, ground-track map) keep
                // the whole width. On iPhone the cap never bites (screen < 700).
                .frame(maxWidth: isFullBleed(shown) ? .infinity : 720)
                .frame(maxWidth: .infinity)
                .scrollContentBackground(.hidden)
                .background(ODTheme.background.ignoresSafeArea())
                // Show the app name on the landing page; other screens keep their
                // own function title.
                .navigationTitle(shown == .home ? "OrbitDeck" : shown.title)
                .navigationBarTitleDisplayMode(.inline)
                // On iPhone the split view collapses to a stack; hide the default
                // "‹ OrbitDeck" back chevron (which reads as "go back", not "open
                // the menu") and offer an explicit hamburger instead.
                .navigationBarBackButtonHidden(horizontalSizeClass == .compact)
                .toolbar {
                    if horizontalSizeClass == .compact {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { selection = nil } label: {
                                Image(systemName: "line.3.horizontal")
                            }
                            .accessibilityLabel("Menu")
                        }
                    }
                    if shown.usesSelectedSatellite {
                        ToolbarItem(placement: .topBarTrailing) {
                            SatelliteSwitcherButton()
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ODTheme.accent)
        // On returning to the foreground, refresh space weather if stale and the
        // catalogs on their weekly cadence.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await store.refreshSpaceWeatherIfNeeded()
                    await store.refreshCatalogsIfNeeded()
                }
                updateLocationFollow()
            } else {
                // Release the GPS while backgrounded; it resumes on foreground.
                autoLocation.stopFollowing()
            }
            applyIdleTimer(active: phase == .active)
        }
        // Follow the device when the operator has chosen "always use current
        // location": continuously track the device while the mode is on and write
        // each fix into the primary observer site, so every live screen recomputes
        // against the operator's real position as they move. On the Home screen the
        // follow runs at full navigation precision so the grid-line/corner readout
        // updates as continuously as the hardware allows.
        .task { updateLocationFollow(); applyIdleTimer(active: scenePhase == .active) }
        .onChange(of: store.locationMode) { _, _ in updateLocationFollow() }
        .onChange(of: selection) { _, newValue in
            if let newValue { lastSelection = newValue }
            updateLocationFollow(); applyIdleTimer(active: scenePhase == .active)
        }
        .onChange(of: keepScreenAwakeHome) { _, _ in applyIdleTimer(active: scenePhase == .active) }
        .onChange(of: notifications.openHomeRequested) { _, requested in
            if requested { selection = .home; notifications.openHomeRequested = false }
        }
        .onChange(of: autoLocation.location) { _, location in
            guard store.locationMode == .currentLocation, let location else { return }
            // Coalesce high-rate fixes to ~1 Hz so downstream live screens don't
            // re-render faster than once per second.
            let now = Date()
            guard now.timeIntervalSince(lastLocationApply) >= 1 else { return }
            lastLocationApply = now
            store.applyCurrentLocation(latitude: location.coordinate.latitude,
                                       longitude: location.coordinate.longitude,
                                       altitudeMeters: location.altitude)
        }
        .alert("OrbitDeck", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    /// Follow the device at coarse (battery-friendly, ~50 m) precision. High-rate
    /// precise fixes are reserved for the Grid Finder (its own provider); a coarse
    /// shared follow keeps the observer current without re-rendering the app faster
    /// than the ~1 Hz throttle below allows.
    private func updateLocationFollow() {
        guard store.locationMode == .currentLocation else { autoLocation.stopFollowing(); return }
        autoLocation.setPrecise(false)
        autoLocation.startFollowing()
    }

    /// Keep the display awake only when the operator opted in, the Home screen is
    /// the current selection, and the app is foreground-active. Any other state
    /// releases the idle timer so the rest of the app auto-locks normally.
    private func applyIdleTimer(active: Bool) {
        UIApplication.shared.isIdleTimerDisabled =
            active && keepScreenAwakeHome && (selection ?? .home) == .home
    }

    /// Explains the toolbar refresh button in the menu.
    private var refreshHelp: String {
        let base = "The ↻ button (top of this menu) downloads the latest orbital element sets (GP/TLE) for the whole catalog from your configured source."
        if let updated = store.lastGPRefresh {
            return base + " Last updated \(updated.formatted(date: .abbreviated, time: .shortened))."
        }
        return base + " Not updated yet this session."
    }

    /// Visual/full-bleed screens that should use the entire detail width rather
    /// than the centered reading column.
    private func isFullBleed(_ destination: OrbitDestination) -> Bool {
        switch destination {
        case .globe, .radar, .groundtrack: return true
        default: return false
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: OrbitDestination) -> some View {
        switch destination {
        case .home: HomeView()
        case .track: TrackView()
        case .globe: GlobeView()
        case .radar: SkyRadarView()
        case .gridfinder: GridFinderView()
        case .passes: PassesView()
        case .skyglance: SkyGlanceView()
        case .schedule: ScheduleView()
        case .passdetail: PassDetailView()
        case .groundtrack: GroundTrackView()
        case .tenday: TenDayView()
        case .orbit: OrbitalAnalysisView()
        case .orbithistory: OrbitalHistoryView()
        case .illum: IlluminationView()
        case .zones: OrbitalZonesView()
        case .ao7: AO7View()
        case .mutual: MutualView()
        case .transits: TransitsView()
        case .astronomy: AstronomyView()
        case .skymap: SkyMapView()
        case .conjunction: ConjunctionView()
        case .grids: WorkableView()
        case .calibrations: CalibrationsView()
        case .radio: RadioView()
        case .log: LogScreen()
        case .sstv: SSTVGalleryScreen()
        case .planning: PlanningView()
        case .tools: DeepToolsView()
        case .graphcalc: GraphCalcView()
        case .tinybasic: DeepTinyBasicView()
        case .datafeeds: DataFeedsView()
        case .amsatstatus: AmsatStatusInteractiveView()
        case .oscarsim: OscarLocatorView()
        case .oscarref: OscarReferenceOrbitsView()
        case .learn: DeepLearnView()
        case .references: ReferencesView()
        case .exports: ExportsView()
        case .sunmoon: SunMoonView()
        case .celestial: CelestialView()
        case .eme: EMEView()
        case .spacewx: SpaceWeatherView()
        case .muf: MUFView()
        case .propagation: PropagationView()
        case .satellites: SatellitesView()
        case .newlaunch: NewLaunchesView()
        case .sites: SitesView()
        case .settings: SettingsView()
        case .about: AboutView()
        default: FeaturePlaceholderView(destination: destination)
        }
    }
}

struct FeaturePlaceholderView: View {
    let destination: OrbitDestination

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: destination.icon)
        } description: {
            Text("This screen is registered in the navigation model, but its implementation is not part of the current build yet.")
        } actions: {
            Text("Core tracking, passes, orbital analysis/history/zones, transits, astronomy, AO-7, mutual windows, sky/celestial tools, conjunction awareness, workable grids, planning, EME, radio, catalog, and settings are functional in this build.")
                .font(.caption)
                .foregroundStyle(ODTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }
}
