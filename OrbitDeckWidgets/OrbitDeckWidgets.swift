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

struct OrbitDeckPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitDeckPassAttributes.self) { context in
            let shown = ShownPass(context.state, at: .now, stale: context.isStale)
            PassActivityContent(shown: shown)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.cyan)
                .widgetURL(shown.url)
        } dynamicIsland: { context in
            // Chosen when iOS draws the activity (on an update, at the stale date),
            // from the embedded pass list. Between draws only the date-driven views
            // (timers, progress) move, so no layout depends on a redraw at AOS or
            // LOS: every countdown sits next to the clock time it runs to ("AOS
            // 14:05Z", "in 0:00" once there), the compact view shows that clock time
            // and the progress views fill from AOS to LOS by themselves.
            let shown = ShownPass(context.state, at: .now, stale: context.isStale)
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
                    .foregroundStyle(shown.pass == nil || shown.stale ? Color.secondary : Color.cyan)
                    // A long name drops below the camera rather than truncating.
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.spokenName)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if shown.pass != nil {
                        PassCountdownColumn(shown: shown, labelStyle: .secondary, timerFont: .title3)
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
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.spokenDetail)
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
                .foregroundStyle(shown.pass == nil || shown.stale ? Color.secondary : Color.cyan)
                .frame(maxWidth: 76, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(shown.spokenName)
            } compactTrailing: {
                PassCompactTime(shown: shown)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 64, alignment: .trailing)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.spokenTiming)
            } minimal: {
                // With two or more Live Activities the island shows only this: a ring
                // over the pass, empty before AOS and filling to LOS by itself.
                PassRing(shown: shown)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(shown.spokenSummary)
            }
            .keylineTint(.cyan)
            .widgetURL(shown.url)
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
        Group {
            switch family {
            case .small:
                PassSmallView(shown: shown)
            default:
                PassLockScreenView(shown: shown).padding(14)
            }
        }
        // One element for VoiceOver: the timers and clock abbreviations read badly.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.spokenSummary)
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
                    .foregroundStyle(shown.pass == nil || shown.stale ? Color.secondary : Color.cyan)
                Text(shown.pass.map { PassPhase.shortName($0.satellite) } ?? "OrbitDeck")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.headline)
            if let pass = shown.pass {
                // "AOS 14:05Z in 4:32": still true once the timer stops at 0:00.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(shown.countdownLabel) in")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    PassCountdown(shown: shown, alignment: .leading)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(shown.timerColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let window = shown.window {
                    ProgressView(timerInterval: window, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(shown.stale ? .secondary : .orange)
                }
                if shown.stale {
                    PassStaleHint()
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(format: "Max %.0f°", pass.maxElevation))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
    /// iOS marked the content out of date (its stale date passed without an
    /// update). Nothing redraws it again until OrbitDeck runs, so the layouts say
    /// so instead of presenting what was drawn as current.
    let stale: Bool

    init(_ state: OrbitDeckPassAttributes.ContentState, at date: Date, stale: Bool) {
        let pass = state.pass(at: date)
        self.pass = pass
        next = pass.flatMap { state.following($0) }
        if let pass { phase = pass.aos <= date ? .up : .upcoming } else { phase = .ended }
        source = state.source
        utc = state.utc
        drawnAt = date
        self.stale = stale
    }

    /// AOS to LOS, as a valid range even for a degenerate pass.
    var window: ClosedRange<Date>? {
        pass.map { $0.aos...max($0.aos.addingTimeInterval(1), $0.los) }
    }

    /// Opens the app on this satellite (nil for content without the NORAD ID).
    var url: URL? { OrbitDeckPassAttributes.url(norad: pass?.norad) }

    /// The event the countdown runs to: AOS when drawn before it, else LOS.
    var target: Date? {
        guard let pass else { return nil }
        return phase == .up ? pass.los : pass.aos
    }

    /// "AOS 14:05Z" or "LOS 14:16Z": the clock time the countdown runs to, so the
    /// pair stays true after the timer has stopped at 0:00.
    var countdownLabel: String {
        guard let target else { return "" }
        return "\(phase == .up ? "LOS" : "AOS") \(PassPhase.clock(target, utc: utc))"
    }

    var timerColor: Color { stale ? .secondary : phase.color }

    // MARK: VoiceOver

    var spokenName: String { pass?.satellite ?? "OrbitDeck" }

    /// "rises at 14:05 UTC" or "overhead, sets at 14:16 UTC": no relative times,
    /// which would turn false between redraws.
    var spokenTiming: String {
        guard let pass else { return "no more planned passes" }
        let timing = switch phase {
        case .upcoming: "rises at \(PassPhase.spokenClock(pass.aos, utc: utc))"
        case .up, .ended: "overhead, sets at \(PassPhase.spokenClock(pass.los, utc: utc))"
        }
        return stale ? "last known pass, \(timing)" : timing
    }

    /// Elevation, directions, set time, what follows, and the stale or ended hint.
    var spokenDetail: String {
        guard let pass else { return "No more planned passes. Open OrbitDeck to plan more." }
        var parts = ["maximum elevation \(Int(pass.maxElevation.rounded())) degrees"]
        if let az = pass.aosAzimuth, phase == .upcoming { parts.append("rises in the \(PassPhase.spokenCompass(az))") }
        var sets = "sets at \(PassPhase.spokenClock(pass.los, utc: utc))"
        if let az = pass.losAzimuth { sets += " in the \(PassPhase.spokenCompass(az))" }
        parts.append(sets)
        if stale {
            parts.append("may be out of date, open OrbitDeck to update")
        } else if let next {
            parts.append("then \(PassPhase.shortName(next.satellite)) at \(PassPhase.spokenClock(next.start, utc: utc))")
        }
        return parts.joined(separator: ", ")
    }

    /// Everything, for the views read as one element.
    var spokenSummary: String {
        guard pass != nil else { return "OrbitDeck, no more planned passes. Open OrbitDeck to plan more." }
        return "\(spokenName), \(spokenTiming), \(spokenDetail)"
    }
}

/// Where the shown pass is; `.ended` means every embedded pass has ended and only
/// the app (or its background refresh) can plan more.
private enum PassPhase {
    case upcoming, up, ended

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

    /// "14:05 UTC" (VoiceOver reads "14:05Z" letter by letter), or local time.
    static func spokenClock(_ date: Date, utc: Bool) -> String {
        guard utc else { return clock(date, utc: false) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date) + " UTC"
    }

    private static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    private static func pointIndex(_ azimuth: Double) -> Int {
        let degrees = (azimuth.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int(degrees / 22.5 + 0.5) % 16
    }

    /// 16-point compass name for an azimuth, e.g. 30 → "NNE".
    static func compass(_ azimuth: Double) -> String {
        points[pointIndex(azimuth)]
    }

    /// The same point spelled out for VoiceOver, e.g. 30 → "north-northeast".
    static func spokenCompass(_ azimuth: Double) -> String {
        let names = ["north", "north-northeast", "northeast", "east-northeast", "east", "east-southeast",
                     "southeast", "south-southeast", "south", "south-southwest", "southwest", "west-southwest",
                     "west", "west-northwest", "northwest", "north-northwest"]
        return names[pointIndex(azimuth)]
    }
}

/// The main countdown: to AOS (stops at 0:00 there), or to LOS when drawn during
/// the pass. The system runs timer text without app updates. Always shown next
/// to `countdownLabel`, the clock time it runs to.
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

/// The expanded and Lock Screen countdown: "AOS 14:05Z" over "in 4:32", in a
/// fixed-width column so the timer (which fills its width) sits right after "in".
/// Once the timer stops at 0:00 at AOS the pair still reads true, while the
/// progress row below takes over.
private struct PassCountdownColumn: View {
    let shown: ShownPass
    let labelStyle: Color
    let timerFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(shown.countdownLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(labelStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("in")
                    .font(.caption)
                    .foregroundStyle(labelStyle)
                    .fixedSize()
                PassCountdown(shown: shown, alignment: .leading)
                    .font(timerFont.monospacedDigit().weight(.semibold))
                    .foregroundStyle(shown.timerColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: 96, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.spokenTiming)
    }
}

/// The compact trailing view: the AOS clock time with a rise arrow (or, drawn
/// during the pass, the LOS time with a set arrow). A clock time stays true
/// through AOS without a redraw, unlike a countdown that would sit at "in 0:00".
private struct PassCompactTime: View {
    let shown: ShownPass

    var body: some View {
        if let target = shown.target {
            HStack(spacing: 2) {
                Image(systemName: shown.stale ? "arrow.clockwise"
                                  : shown.phase == .up ? "arrow.down.right" : "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                Text(PassPhase.clock(target, utc: shown.utc))
            }
            .foregroundStyle(shown.timerColor)
        } else {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.secondary)
        }
    }
}

/// The minimal presentation: a ring over the pass, empty before AOS and filling
/// to LOS. Animated by the system, no updates needed.
private struct PassRing: View {
    let shown: ShownPass

    var body: some View {
        if let window = shown.window {
            ProgressView(timerInterval: window, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(shown.stale ? Color.secondary : Color.cyan)
            }
            .progressViewStyle(.circular)
            .tint(shown.stale ? .secondary : .orange)
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        }
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
                .tint(shown.stale ? .secondary : .orange)
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

/// "Open OrbitDeck to update", for content iOS has marked out of date.
private struct PassStaleHint: View {
    var body: some View {
        Label {
            Text("Open OrbitDeck to update")
        } icon: {
            Image(systemName: "arrow.clockwise")
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// How the pass was chosen and what follows it, or how to get more.
private struct PassFooterLine: View {
    let shown: ShownPass

    var body: some View {
        Group {
            if shown.stale && shown.pass != nil {
                // The times above are the last known pass; what follows it (and
                // whether the plan still holds) needs the app.
                PassStaleHint()
            } else if let pass = shown.pass {
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
                    .foregroundStyle(shown.pass == nil || shown.stale ? Color.secondary : Color.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shown.pass?.satellite ?? "OrbitDeck")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(shown.stale ? 0.7 : 1))
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
                    PassCountdownColumn(shown: shown, labelStyle: .white.opacity(0.7), timerFont: .title2)
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
