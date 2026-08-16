import SwiftUI

enum OrbitDestination: String, CaseIterable, Identifiable, Hashable {
    case home, track, globe, radar
    case passes, skyglance, passdetail, groundtrack, tenday
    case orbit, orbithistory, illum, zones, ao7, mutual, transits, astronomy, skymap, conjunction, grids
    case radio, planning, tools, graphcalc, tinybasic, datafeeds, amsatstatus, oscarsim, learn, references, exports
    case sunmoon, celestial, eme, spacewx, muf, propagation
    case satellites, newlaunch, sites, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .track: "Track"
        case .globe: "3D Globe"
        case .radar: "Sky Radar"
        case .passes: "Next Passes"
        case .skyglance: "Sky at a Glance"
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
        case .planning: "Planning"
        case .tools: "Tools"
        case .graphcalc: "Graphing Calc"
        case .tinybasic: "Tiny BASIC"
        case .datafeeds: "Activations / QRZ"
        case .amsatstatus: "AMSAT Status"
        case .oscarsim: "OSCARLOCATOR Sim"
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
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .track: "scope"
        case .globe: "globe.americas"
        case .radar: "dot.radiowaves.left.and.right"
        case .passes: "clock.arrow.2.circlepath"
        case .skyglance: "sparkles"
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
        case .planning: "calendar"
        case .tools: "wrench.and.screwdriver"
        case .graphcalc: "function"
        case .tinybasic: "terminal"
        case .datafeeds: "antenna.radiowaves.left.and.right"
        case .amsatstatus: "waveform.path.ecg"
        case .oscarsim: "scope"
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
        case .settings: "gearshape"
        }
    }

    /// Screens that don't act on the active satellite shouldn't show the global
    /// satellite switcher in their toolbar.
    var usesSelectedSatellite: Bool {
        switch self {
        case .radar, .sunmoon, .spacewx, .muf, .propagation, .tools, .graphcalc, .tinybasic,
             .datafeeds, .learn, .references, .newlaunch, .sites, .astronomy, .eme,
             .satellites, .settings:
            return false
        default:
            return true
        }
    }

    var implemented: Bool {
        switch self {
        case .home, .track, .globe, .radar, .passes, .skyglance, .passdetail, .groundtrack, .tenday,
             .orbit, .orbithistory, .illum, .zones, .ao7, .mutual, .transits, .astronomy,
             .skymap, .conjunction, .grids,
             .radio, .planning, .tools, .graphcalc, .tinybasic, .datafeeds, .amsatstatus, .oscarsim, .learn, .references, .exports, .sunmoon, .celestial, .eme, .spacewx, .muf, .propagation,
             .satellites, .newlaunch, .sites, .settings:
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
    NavGroup(id: "live", title: "LIVE", items: [.home, .globe, .radar]),
    NavGroup(id: "passes", title: "PASSES", items: [.passes, .skyglance, .groundtrack, .tenday]),
    NavGroup(id: "analysis", title: "ANALYSIS", items: [.orbit, .orbithistory, .illum, .zones, .ao7, .mutual, .transits, .astronomy, .skymap, .conjunction, .grids]),
    NavGroup(id: "operating", title: "OPERATING TOOLS", items: [.radio, .planning, .tools, .graphcalc, .tinybasic, .datafeeds, .amsatstatus, .oscarsim, .learn, .references, .exports]),
    NavGroup(id: "sky", title: "SKY & SPACE", items: [.sunmoon, .celestial, .eme, .spacewx, .muf, .propagation]),
    NavGroup(id: "catalog", title: "CATALOG & CONFIGURATION", items: [.satellites, .newlaunch, .sites, .settings])
]

struct RootView: View {
    @EnvironmentObject private var store: OrbitStore
    @State private var selection: OrbitDestination? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

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
                        .accessibilityLabel("Update GP")
                    }
                }
            }
        } detail: {
            destinationView(selection ?? .home)
                .scrollContentBackground(.hidden)
                .background(ODTheme.background.ignoresSafeArea())
                .navigationTitle(selection?.title ?? "OrbitDeck")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if (selection ?? .home).usesSelectedSatellite {
                        ToolbarItem(placement: .topBarTrailing) {
                            SatelliteSwitcherButton()
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(ODTheme.accent)
        .alert("OrbitDeck", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.clearError() } }
        )) {
            Button("OK", role: .cancel) { store.clearError() }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: OrbitDestination) -> some View {
        switch destination {
        case .home: HomeView()
        case .track: TrackView()
        case .globe: GlobeView()
        case .radar: SkyRadarView()
        case .passes: PassesView()
        case .skyglance: SkyGlanceView()
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
        case .radio: RadioView()
        case .planning: PlanningView()
        case .tools: DeepToolsView()
        case .graphcalc: GraphCalcView()
        case .tinybasic: DeepTinyBasicView()
        case .datafeeds: DataFeedsView()
        case .amsatstatus: AmsatStatusInteractiveView()
        case .oscarsim: OscarLocatorView()
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
