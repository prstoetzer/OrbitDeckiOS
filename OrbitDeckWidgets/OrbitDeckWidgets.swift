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

    struct ContentState: Codable, Hashable {
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
    }
}

struct OrbitDeckPassLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbitDeckPassAttributes.self) { context in
            PassLockScreenView(state: context.state, isStale: context.isStale)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(.cyan)
        } dynamicIsland: { context in
            let state = context.state
            let phase = PassPhase(state, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    Label {
                        Text(state.satellite)
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
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(phase.countdownLabel).font(.caption2).foregroundStyle(.secondary)
                        PassCountdown(state: state, phase: phase)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(phase.color)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PassDetailLine(state: state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                // Compact width shrinks when another app shares the island; fall back
                // from icon + name to a shorter name, then to the icon alone.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(state.satellite)
                    }
                    Text(PassPhase.shortName(state.satellite))
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .lineLimit(1)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(maxWidth: 76, alignment: .leading)
            } compactTrailing: {
                PassCountdown(state: state, phase: phase)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(phase.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                // With two or more Live Activities the island shows only this; a
                // self-updating ring keeps the time left visible (to AOS within the
                // last hour, or to LOS during the pass).
                PassRing(state: state, phase: phase)
            }
            .keylineTint(.cyan)
        }
    }
}

/// Where the shown pass is. The app marks the content stale at the next
/// transition when it couldn't refresh: at AOS for an upcoming pass (so it is
/// treated as in progress) and at LOS for one in progress (so it has ended).
private enum PassPhase {
    case upcoming, up, ended

    init(_ state: OrbitDeckPassAttributes.ContentState, isStale: Bool) {
        if state.inPass { self = isStale ? .ended : .up } else { self = isStale ? .up : .upcoming }
    }

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
    let state: OrbitDeckPassAttributes.ContentState
    let phase: PassPhase

    var body: some View {
        switch phase {
        case .up:
            Text(timerInterval: state.aos...max(state.aos, state.los), countsDown: true)
                .multilineTextAlignment(.trailing)
        case .upcoming:
            let now = Date()
            Text(timerInterval: now...max(now, state.aos), countsDown: true)
                .multilineTextAlignment(.trailing)
        case .ended:
            Text("ended")
        }
    }
}

/// The minimal presentation: a ring that drains to AOS over the final hour (full
/// until then), then over the pass to LOS. Animated by the system, no updates needed.
private struct PassRing: View {
    let state: OrbitDeckPassAttributes.ContentState
    let phase: PassPhase

    var body: some View {
        switch phase {
        case .upcoming:
            ring(state.aos.addingTimeInterval(-3600)...state.aos)
        case .up:
            ring(state.aos...max(state.aos, state.los))
        case .ended:
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
        .tint(phase.color)
        .foregroundStyle(phase.color)
    }
}

private struct PassDetailLine: View {
    let state: OrbitDeckPassAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AOS \(PassPhase.clock(state.aos, utc: state.utc)) · LOS \(PassPhase.clock(state.los, utc: state.utc)) · max \(Int(state.maxElevation.rounded()))°")
            if let switchAt = state.switchAt {
                Text("Auto switch at \(PassPhase.clock(switchAt, utc: state.utc))")
            } else {
                Text(state.source == .priority ? "Next priority satellite" : "Next favorite pass")
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PassLockScreenView: View {
    let state: OrbitDeckPassAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let phase = PassPhase(state, isStale: isStale)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.satellite)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                PassDetailLine(state: state)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(phase.countdownLabel)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                PassCountdown(state: state, phase: phase)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(phase.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: 90, alignment: .trailing)
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
