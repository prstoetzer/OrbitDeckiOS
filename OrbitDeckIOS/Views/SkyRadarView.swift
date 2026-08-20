import SwiftUI

private struct RadarBlip: Identifiable, Sendable {
    let id: UInt
    let name: String
    let azimuth: Double
    let elevation: Double
}

/// Live all-sky radar: every catalog satellite currently above the horizon,
/// plotted on an azimuth/elevation polar chart and listed below.
struct SkyRadarView: View {
    @EnvironmentObject private var store: OrbitStore

    var body: some View {
        // Recompute every second on the TimelineView tick (the reliable live-update
        // path on-device); the all-satellite look-angle scan is cheap enough to run
        // synchronously here.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let blips = computeBlips(at: context.date)
            VStack(spacing: 0) {
                HStack {
                    Text("Sky Radar").font(.headline)
                    Spacer()
                    Text("\(blips.count) above horizon")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ODTheme.muted)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(ODTheme.panel)

                ScrollView {
                    VStack(spacing: 14) {
                        radar(blips)
                            .aspectRatio(1, contentMode: .fit)
                            .padding()

                        if blips.isEmpty {
                            Text("No catalog satellites are above the horizon right now.")
                                .font(.caption).foregroundStyle(ODTheme.muted)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(blips) { blip in
                                    Button { store.select(blip.id) } label: {
                                        HStack {
                                            Circle()
                                                .fill(blip.id == store.selectedSatellite?.id ? ODTheme.accent : ODTheme.good)
                                                .frame(width: 8, height: 8)
                                            Text(blip.name)
                                                .foregroundStyle(blip.id == store.selectedSatellite?.id ? ODTheme.accent : .primary)
                                            Spacer()
                                            Text("el \(ODFormat.angle(blip.elevation)) · \(ODFormat.compass(blip.azimuth)) \(ODFormat.angle(blip.azimuth, decimals: 0))")
                                                .font(.caption.monospacedDigit()).foregroundStyle(ODTheme.muted)
                                        }
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func computeBlips(at date: Date) -> [RadarBlip] {
        let observer = store.preferences.observer
        var output: [RadarBlip] = []
        for satellite in store.satellites {
            if let look = try? OrbitPredictor.look(satellite, observer: observer, at: date), look.elevation >= 0 {
                output.append(RadarBlip(id: satellite.id, name: satellite.name, azimuth: look.azimuth, elevation: look.elevation))
            }
        }
        return output.sorted { $0.elevation > $1.elevation }
    }

    private func radar(_ blips: [RadarBlip]) -> some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = max(1, side / 2 - 22)

            for elevation in stride(from: 0.0, through: 90.0, by: 30.0) {
                let r = outer * (90 - elevation) / 90
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(ODTheme.grid), lineWidth: elevation == 0 ? 1.5 : 0.8)
            }
            var cross = Path()
            cross.move(to: CGPoint(x: center.x, y: center.y - outer)); cross.addLine(to: CGPoint(x: center.x, y: center.y + outer))
            cross.move(to: CGPoint(x: center.x - outer, y: center.y)); cross.addLine(to: CGPoint(x: center.x + outer, y: center.y))
            context.stroke(cross, with: .color(ODTheme.grid.opacity(0.8)), lineWidth: 0.7)

            // Track occupied label rectangles so crowded blips don't stack names.
            var placedLabels: [CGRect] = []
            func placeLabel(_ resolved: GraphicsContext.ResolvedText, near anchorPoint: CGPoint) -> CGPoint {
                let size = resolved.measure(in: CGSize(width: 240, height: 40))
                let candidates: [CGPoint] = [
                    anchorPoint,
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y - 10),
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y + 10),
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y - 20),
                    CGPoint(x: anchorPoint.x, y: anchorPoint.y + 20)
                ]
                for candidate in candidates {
                    let rect = CGRect(x: candidate.x - size.width / 2, y: candidate.y - size.height / 2,
                                      width: size.width, height: size.height)
                    if !placedLabels.contains(where: { $0.intersects(rect) }) {
                        placedLabels.append(rect)
                        return candidate
                    }
                }
                let fallback = candidates[0]
                placedLabels.append(CGRect(x: fallback.x - size.width / 2, y: fallback.y - size.height / 2,
                                           width: size.width, height: size.height))
                return fallback
            }

            for (label, azimuth) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                let a = azimuth * .pi / 180
                let p = CGPoint(x: center.x + (outer + 12) * sin(a), y: center.y - (outer + 12) * cos(a))
                let resolved = context.resolve(Text(label).font(.caption.bold()).foregroundStyle(ODTheme.muted))
                let size = resolved.measure(in: CGSize(width: 40, height: 40))
                placedLabels.append(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                           width: size.width, height: size.height))
                context.draw(resolved, at: p)
            }

            for blip in blips {
                let r = outer * (90 - max(0, min(90, blip.elevation))) / 90
                let a = blip.azimuth * .pi / 180
                let p = CGPoint(x: center.x + r * sin(a), y: center.y - r * cos(a))
                let color = blip.id == store.selectedSatellite?.id ? ODTheme.accent : ODTheme.good
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
                let resolved = context.resolve(Text(blip.name).font(.system(size: 8, weight: .semibold)).foregroundStyle(color))
                let labelPos = placeLabel(resolved, near: CGPoint(x: p.x, y: p.y - 11))
                if abs(labelPos.y - (p.y - 11)) > 6 {
                    var leader = Path()
                    leader.move(to: CGPoint(x: p.x, y: p.y))
                    leader.addLine(to: labelPos)
                    context.stroke(leader, with: .color(color.opacity(0.35)), lineWidth: 0.6)
                }
                context.draw(resolved, at: labelPos)
            }
        }
        .background(ODTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("All-sky radar")
    }
}
