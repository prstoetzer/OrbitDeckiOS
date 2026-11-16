import ActivityKit
import SwiftUI
import WidgetKit

/// The next-pass Live Activity (Lock Screen and Dynamic Island).
///
/// KEEP IN SYNC: the app target declares an identical `OrbitDeckPassAttributes`
/// in OrbitStore.swift. ActivityKit hands the content across by type name and
/// Codable shape, so the two copies must match field for field.
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

        enum CodingKeys: String, CodingKey {
            case satellite = "n", aos = "a", los = "l", maxElevation = "e", switchAt = "s"
            case aosAzimuth = "aa", losAzimuth = "la"
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
        /// The widget's countdowns cover AOS by themselves, so this is the one
        /// redraw that matters: the stale date.
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

struct OrbitDeckPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitDeckPassAttributes.self) { context in
            PassActivityContent(shown: ShownPass(context.state, at: .now))
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            // Chosen when iOS draws the activity (on an update, at the stale date),
            // from the embedded pass list. Between draws only the date-driven views
            // (timers, progress) move, so every layout reads right through AOS
            // without a redraw: the AOS countdown stops at 0:00 while the pass-left
            // timer and the progress bar take over.
            let shown = ShownPass(context.state, at: .now)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    Label {
                        Text(shown.pass?.satellite ?? "OrbitDeck")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .font(.headline)
                    .foregroundStyle(.cyan)
                    // A long name drops below the camera rather than truncating.
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if shown.pass != nil {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(shown.phase.countdownLabel).font(.caption2).foregroundStyle(.secondary)
                            PassCountdown(shown: shown)
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(shown.phase.color)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: 96, alignment: .trailing)
                        }
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        PassTimesLine(shown: shown)
                        PassProgressRow(shown: shown)
                        PassFooterLine(shown: shown)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                // Compact width shrinks when another app shares the island; fall back
                // from icon + name to a shorter name, then to the icon alone.
                Group {
                    if let pass = shown.pass {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 3) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text(pass.satellite)
                            }
                            Text(PassPhase.shortName(pass.satellite))
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                }
                .lineLimit(1)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(shown.pass == nil ? Color.secondary : Color.cyan)
                .frame(maxWidth: 76, alignment: .leading)
            } compactTrailing: {
                // A bare "17:58" here read as a clock time, so the AOS countdown is
                // prefixed "in". (During the pass the orange LOS countdown is the
                // time left.) The timer text fills the remaining width, so it's
                // leading-aligned to sit right after the prefix.
                HStack(spacing: 2) {
                    if shown.phase == .upcoming {
                        Text("in").fixedSize()
                    }
                    PassCountdown(shown: shown, alignment: shown.phase == .upcoming ? .leading : .trailing)
                }
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(shown.phase.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: 64, alignment: .trailing)
            } minimal: {
                // With two or more Live Activities the island shows only this; a
                // self-updating ring keeps the time left visible (to AOS within the
                // last hour, or to LOS during the pass).
                PassRing(shown: shown)
            }
            .keylineTint(.cyan)
        }
        // The small family is the Apple Watch Smart Stack (and CarPlay); the Lock
        // Screen and StandBy keep the medium layout.
        .supplementalActivityFamilies([.small, .medium])
    }
}

/// Picks the Lock Screen layout or the compact Smart Stack one.
private struct PassActivityContent: View {
    @Environment(\.activityFamily) private var family
    let shown: ShownPass

    var body: some View {
        switch family {
        case .small:
            PassSmallView(shown: shown)
        default:
            PassLockScreenView(shown: shown).padding(14)
        }
    }
}

/// The Smart Stack layout: name, the live countdown and the pass progress — no
/// more than a watch face fits.
private struct PassSmallView: View {
    let shown: ShownPass

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(shown.pass == nil ? Color.secondary : Color.cyan)
                Text(shown.pass.map { PassPhase.shortName($0.satellite) } ?? "OrbitDeck")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.headline)
            if let pass = shown.pass {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(shown.phase.countdownLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    PassCountdown(shown: shown)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(shown.phase.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let window = shown.window {
                    ProgressView(timerInterval: window, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(.orange)
                }
                Text(String(format: "Max %.0f°", pass.maxElevation))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("Open OrbitDeck to plan more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}

/// The pass picked for display at render time, and where it is.
private struct ShownPass {
    let pass: OrbitDeckPassAttributes.Pass?
    /// The one after it in the list, for "Then …".
    let next: OrbitDeckPassAttributes.Pass?
    let phase: PassPhase
    let source: OrbitDeckPassAttributes.Source
    let utc: Bool
    /// When this was drawn: the start of the AOS countdown.
    let drawnAt: Date

    init(_ state: OrbitDeckPassAttributes.ContentState, at date: Date) {
        let pass = state.pass(at: date)
        self.pass = pass
        next = pass.flatMap { state.following($0) }
        if let pass { phase = pass.aos <= date ? .up : .upcoming } else { phase = .ended }
        source = state.source
        utc = state.utc
        drawnAt = date
    }

    /// AOS to LOS, as a valid range even for a degenerate pass.
    var window: ClosedRange<Date>? {
        pass.map { $0.aos...max($0.aos.addingTimeInterval(1), $0.los) }
    }
}

/// Where the shown pass is; `.ended` means every embedded pass has ended and only
/// the app (or its background refresh) can plan more.
private enum PassPhase {
    case upcoming, up, ended

    var countdownLabel: String {
        switch self {
        case .upcoming: "AOS in"
        case .up: "LOS in"
        case .ended: "Pass"
        }
    }

    var color: Color {
        switch self {
        case .upcoming: .green
        case .up: .orange
        case .ended: .secondary
        }
    }

    /// "ISS (ZARYA)" → "ISS", "AO-7_[U/v]" → "AO-7" for the narrowest layouts.
    static func shortName(_ name: String) -> String {
        let cut = name.firstIndex { $0 == "(" || $0 == "[" || $0 == "_" } ?? name.endIndex
        let short = name[..<cut].trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? name : short
    }

    static func clock(_ date: Date, utc: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if utc {
            formatter.dateFormat = "HH:mm'Z'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
        } else {
            formatter.locale = .current
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }

    /// 16-point compass name for an azimuth, e.g. 30 → "NNE".
    static func compass(_ azimuth: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                      "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let degrees = (azimuth.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int(degrees / 22.5 + 0.5) % 16]
    }
}

/// The main countdown: to AOS (stops at 0:00 there), or to LOS when drawn during
/// the pass. The system runs timer text without app updates.
private struct PassCountdown: View {
    let shown: ShownPass
    var alignment: TextAlignment = .trailing

    var body: some View {
        if let window = shown.window, shown.phase == .up {
            Text(timerInterval: window, countsDown: true)
                .multilineTextAlignment(alignment)
        } else if let pass = shown.pass {
            Text(timerInterval: shown.drawnAt...max(shown.drawnAt, pass.aos), countsDown: true)
                .multilineTextAlignment(alignment)
        } else {
            Image(systemName: "arrow.clockwise")
        }
    }
}

/// The minimal presentation: a ring that drains to AOS over the final hour (full
/// until then), then over the pass to LOS. Animated by the system, no updates needed.
private struct PassRing: View {
    let shown: ShownPass

    var body: some View {
        if let window = shown.window, shown.phase == .up {
            ring(window)
        } else if let pass = shown.pass {
            ring(pass.aos.addingTimeInterval(-3600)...pass.aos)
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        }
    }

    private func ring(_ interval: ClosedRange<Date>) -> some View {
        ProgressView(timerInterval: interval, countsDown: true) {
            EmptyView()
        } currentValueLabel: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 9, weight: .semibold))
        }
        .progressViewStyle(.circular)
        .tint(shown.phase.color)
        .foregroundStyle(shown.phase.color)
    }
}

/// "AOS 14:05Z NE · max 54° · LOS 14:16Z SSE", shortened to fit.
private struct PassTimesLine: View {
    let shown: ShownPass

    var body: some View {
        Group {
            if let pass = shown.pass {
                let aos = PassPhase.clock(pass.aos, utc: shown.utc)
                let los = PassPhase.clock(pass.los, utc: shown.utc)
                let max = "max \(Int(pass.maxElevation.rounded()))°"
                if let aosAz = pass.aosAzimuth, let losAz = pass.losAzimuth {
                    ViewThatFits(in: .horizontal) {
                        Text("AOS \(aos) \(PassPhase.compass(aosAz)) · \(max) · LOS \(los) \(PassPhase.compass(losAz))")
                        Text("\(aos) \(PassPhase.compass(aosAz)) · \(max) · \(los) \(PassPhase.compass(losAz))")
                        Text("AOS \(aos) · \(max) · LOS \(los)")
                    }
                } else {
                    Text("AOS \(aos) · \(max) · LOS \(los)")
                }
            } else {
                Text("No more planned passes")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A bar across the pass, empty before AOS and full at LOS, and the time left in
/// the pass (its full length until AOS). Both run by themselves, so the activity
/// reads right through the whole pass even if iOS never redraws it.
private struct PassProgressRow: View {
    let shown: ShownPass

    var body: some View {
        if let window = shown.window {
            HStack(spacing: 8) {
                ProgressView(timerInterval: window, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(.orange)
                if shown.phase == .upcoming {
                    // The big countdown shows LOS once drawn in the pass; before AOS
                    // this one shows the pass length, then counts down to LOS.
                    HStack(spacing: 3) {
                        Text("Up for")
                        Text(timerInterval: window, countsDown: true)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 56, alignment: .trailing)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

/// How the pass was chosen and what follows it, or how to get more.
private struct PassFooterLine: View {
    let shown: ShownPass

    var body: some View {
        Group {
            if let pass = shown.pass {
                let reason = if let switchAt = pass.switchAt {
                    "Auto switch \(PassPhase.clock(switchAt, utc: shown.utc))"
                } else {
                    shown.source == .priority ? "Priority satellite" : "Favorite pass"
                }
                if let next = shown.next {
                    let then = "Then \(PassPhase.shortName(next.satellite)) \(PassPhase.clock(next.start, utc: shown.utc))"
                    ViewThatFits(in: .horizontal) {
                        Text("\(reason) · \(then)")
                        Text(then)
                    }
                } else {
                    Text(reason)
                }
            } else {
                Text("Open OrbitDeck to plan more")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PassLockScreenView: View {
    let shown: ShownPass

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(shown.pass == nil ? Color.secondary : Color.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.pass?.satellite ?? "OrbitDeck")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Group {
                        PassTimesLine(shown: shown)
                        PassFooterLine(shown: shown)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                if shown.pass != nil {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(shown.phase.countdownLabel)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                        PassCountdown(shown: shown)
                            .font(.title2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(shown.phase.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: 96, alignment: .trailing)
                    }
                }
            }
            PassProgressRow(shown: shown)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

private extension OrbitDeckPassAttributes.ContentState {
    /// Preview content from (name, switch, AOS, LOS, max elevation), times in minutes from now.
    static func preview(_ source: OrbitDeckPassAttributes.Source, utc: Bool,
                        _ items: [(String, Double?, Double, Double, Double)]) -> Self {
        let now = Date.now
        let passes = items.map { name, switchAt, aos, los, maxEl in
            OrbitDeckPassAttributes.Pass(satellite: name, aos: now.addingTimeInterval(aos * 60),
                                         los: now.addingTimeInterval(los * 60), maxElevation: maxEl,
                                         switchAt: switchAt.map { now.addingTimeInterval($0 * 60) },
                                         aosAzimuth: 20, losAzimuth: 160)
        }
        let first = passes.first ?? OrbitDeckPassAttributes.Pass(satellite: "ISS", aos: now, los: now, maxElevation: 0)
        return Self(satellite: first.satellite, aos: first.aos, los: first.los, maxElevation: first.maxElevation,
                    switchAt: first.switchAt, source: source, inPass: first.aos <= now, utc: utc,
                    passes: passes.isEmpty ? [first] : passes)
    }
}

#Preview("Lock Screen", as: .content, using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState.preview(.priority, utc: true,
                                                  [("ISS (ZARYA)", 14, 15, 25, 54), ("AO-91", nil, 110, 122, 31)])
    OrbitDeckPassAttributes.ContentState.preview(.favorite, utc: false,
                                                  [("SO-50", nil, -2, 8, 31), ("AO-7_[U/v]", nil, 95, 112, 62)])
    // Content from a build before the look-ahead list.
    OrbitDeckPassAttributes.ContentState(satellite: "SO-50", aos: .now.addingTimeInterval(600),
                                         los: .now.addingTimeInterval(1200), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: false, utc: true)
    // Every embedded pass has ended and the app hasn't refreshed.
    OrbitDeckPassAttributes.ContentState(satellite: "SO-50", aos: .now.addingTimeInterval(-900),
                                         los: .now.addingTimeInterval(-300), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: true, utc: false,
                                         passes: [])
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState.preview(.priority, utc: true, [("ISS (ZARYA)", nil, 90, 100, 54)])
    OrbitDeckPassAttributes.ContentState.preview(.favorite, utc: false, [("AO-7_[U/v]", nil, -2, 13, 31)])
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState.preview(.priority, utc: true, [("ISS (ZARYA)", nil, 20, 30, 54)])
    OrbitDeckPassAttributes.ContentState.preview(.favorite, utc: false, [("SO-50", nil, -4, 6, 31)])
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState.preview(.priority, utc: true,
                                                  [("TEVEL2-9 (RADFXSAT-2)", 65, 66, 76, 72), ("ISS (ZARYA)", 140, 141, 151, 40)])
}
