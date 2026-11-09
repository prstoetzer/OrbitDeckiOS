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

struct OrbitDeckPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitDeckPassAttributes.self) { context in
            PassLockScreenView(shown: ShownPass(context.state, at: .now))
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            // Chosen at render time from the embedded pass list, so whenever the
            // system redraws (at the stale date, on expansion, on the Lock Screen)
            // it shows the right pass even if the app hasn't run since.
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
                        }
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PassDetailLine(shown: shown)
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
                PassCountdown(shown: shown)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(shown.phase.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                // With two or more Live Activities the island shows only this; a
                // self-updating ring keeps the time left visible (to AOS within the
                // last hour, or to LOS during the pass).
                PassRing(shown: shown)
            }
            .keylineTint(.cyan)
        }
    }
}

/// The pass picked for display at render time, and where it is.
private struct ShownPass {
    let pass: OrbitDeckPassAttributes.Pass?
    let phase: PassPhase
    let source: OrbitDeckPassAttributes.Source
    let utc: Bool

    init(_ state: OrbitDeckPassAttributes.ContentState, at date: Date) {
        pass = state.pass(at: date)
        if let pass { phase = pass.aos <= date ? .up : .upcoming } else { phase = .ended }
        source = state.source
        utc = state.utc
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
}

/// A self-updating countdown to AOS, or to LOS once the pass is up. The system
/// animates timer text without app updates, and it stops at 0:00.
private struct PassCountdown: View {
    let shown: ShownPass

    var body: some View {
        if let pass = shown.pass, shown.phase == .up {
            Text(timerInterval: pass.aos...max(pass.aos, pass.los), countsDown: true)
                .multilineTextAlignment(.trailing)
        } else if let pass = shown.pass {
            let now = Date()
            Text(timerInterval: now...max(now, pass.aos), countsDown: true)
                .multilineTextAlignment(.trailing)
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
        if let pass = shown.pass, shown.phase == .up {
            ring(pass.aos...max(pass.aos, pass.los))
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

private struct PassDetailLine: View {
    let shown: ShownPass

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let pass = shown.pass {
                Text("AOS \(PassPhase.clock(pass.aos, utc: shown.utc)) · LOS \(PassPhase.clock(pass.los, utc: shown.utc)) · max \(Int(pass.maxElevation.rounded()))°")
                if let switchAt = pass.switchAt {
                    Text("Auto switch at \(PassPhase.clock(switchAt, utc: shown.utc))")
                } else {
                    Text(shown.source == .priority ? "Next priority satellite" : "Next favorite pass")
                }
            } else {
                Text("No more planned passes")
                Text("Open OrbitDeck to refresh")
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(shown.pass == nil ? Color.secondary : Color.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(shown.pass?.satellite ?? "OrbitDeck")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                PassDetailLine(shown: shown)
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
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
        }
    }
}

#Preview("Lock Screen", as: .content, using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState(satellite: "ISS (ZARYA)", aos: .now.addingTimeInterval(900),
                                         los: .now.addingTimeInterval(1500), maxElevation: 54,
                                         switchAt: .now.addingTimeInterval(840), source: .priority,
                                         inPass: false, utc: true)
    OrbitDeckPassAttributes.ContentState(satellite: "SO-50", aos: .now.addingTimeInterval(-120),
                                         los: .now.addingTimeInterval(480), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: true, utc: false)
    // Every embedded pass has ended and the app hasn't refreshed.
    OrbitDeckPassAttributes.ContentState(satellite: "SO-50", aos: .now.addingTimeInterval(-900),
                                         los: .now.addingTimeInterval(-300), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: true, utc: false,
                                         passes: [])
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState(satellite: "ISS (ZARYA)", aos: .now.addingTimeInterval(5400),
                                         los: .now.addingTimeInterval(6000), maxElevation: 54,
                                         switchAt: nil, source: .priority, inPass: false, utc: true)
    OrbitDeckPassAttributes.ContentState(satellite: "AO-7_[U/v]", aos: .now.addingTimeInterval(-120),
                                         los: .now.addingTimeInterval(780), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: true, utc: false)
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState(satellite: "ISS (ZARYA)", aos: .now.addingTimeInterval(1200),
                                         los: .now.addingTimeInterval(1800), maxElevation: 54,
                                         switchAt: nil, source: .priority, inPass: false, utc: true)
    OrbitDeckPassAttributes.ContentState(satellite: "SO-50", aos: .now.addingTimeInterval(-240),
                                         los: .now.addingTimeInterval(360), maxElevation: 31,
                                         switchAt: nil, source: .favorite, inPass: true, utc: false)
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: OrbitDeckPassAttributes()) {
    OrbitDeckPassLiveActivity()
} contentStates: {
    OrbitDeckPassAttributes.ContentState(satellite: "TEVEL2-9 (RADFXSAT-2)", aos: .now.addingTimeInterval(4000),
                                         los: .now.addingTimeInterval(4600), maxElevation: 72,
                                         switchAt: .now.addingTimeInterval(3940), source: .priority,
                                         inPass: false, utc: true)
}
