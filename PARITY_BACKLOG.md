# OrbitDeck iOS — Feature Parity Backlog

_Generated from a screen-by-screen audit of the original Python app vs the iOS port._
_Overall parity at audit time: **70%** across 41 screens._

_Update 2026-08-15: all 28 ranked gaps are now ✅ done. The remaining work is the cross-cutting polish themes below (severity color-coding, per-screen summary lines, uncapping truncated lists, restoring configurable pickers)._

## Ranked top gaps

| # | Screen | Gap | Sev | Effort | Status |
|---|--------|-----|-----|--------|--------|
| 1 | Home | Restore fleet dashboard: overhead-now + next-passes-across-all-favorites on Home | high | M | ✅ done |
| 2 | Sky Radar | Live mode should plot all favorites simultaneously, not just the selected satellite | high | L | ✅ done (plots whole catalog above horizon live; labels de-collided) |
| 3 | Orbital Analysis | Rebuild as tabbed screen surfacing Live/Next-Pass/Nodal/Sun-Beta/Position pages (engine already computes these) | high | M | ✅ done (tabbed Live/Elements/Nodal/Doppler) |
| 4 | Track | Add live Doppler frequency block (DN/RX/UP/TX + shifts) to TrackView | high | M | ✅ done |
| 5 | Track | Add live AOS/LOS next-event countdown row to TrackView | high | M | ✅ done |
| 6 | Satellites | Restore 'What's up now' whole-catalog instantaneous visibility scan tab | high | M | ✅ done |
| 7 | Satellites | Restore 'By type' catalog grouped by transponder category with filter/sort | high | M | ✅ done |
| 8 | Next Passes | Add pass quality score (0-100) column and best-pass star | high | S | ✅ done |
| 9 | Next Passes | Add inline min-elevation preset picker (0/5/10/20/30 deg) on the screen | high | S | ✅ done |
| 10 | Next Passes | Wire row tap to open Pass Detail preloaded with that specific pass | high | M | ✅ done |
| 11 | Space Wx | Add aurora likelihood row (Kp-derived) to Space Weather screen | high | S | ✅ done |
| 12 | AO-7 Mode | Filter AMSAT reports to current continuous-sunlight window before fitting (accuracy fix) | high | S | ✅ done (AO7Service.fetchAndFit(sinceSunlightStart:)) |
| 13 | Workable | Add ~3s live auto-refresh timer for Live-footprint mode | high | S | ✅ done |
| 14 | New Launches | Re-filter cached results on toggle without a new network scan (broken toggle) | high | M | ✅ done |
| 15 | New Launches | Expand noise-filter token list from 27 to 59 (32 missing constellation tokens leak through) | medium | S | ✅ done |
| 16 | Home | Add Space Weather glance panel (SFI + Kp) to Home dashboard | medium | S | ✅ done |
| 17 | Sky Radar | Add all-passes overlay mode (raise hardcoded maxCount:1) | high | M | ✅ done (superseded by whole-catalog live radar) |
| 18 | Track | Draw next-pass arc on TrackView polar plot (SkyRadarView already computes it) | medium | S | ✅ done |
| 19 | Pass Detail | Add elevation-vs-time Cartesian profile chart beside the polar plot | high | M | ✅ done |
| 20 | Sun/Moon | Show below-horizon ghost markers for Sun and Moon on polar plot (currently dropped) | medium | M | ✅ done |
| 21 | Ground Track | Add orbits-ahead selector (1/3/5/8) and forward-only projection | high | M | ✅ done |
| 22 | MUF / HF Prop | Restore DXCC entity lookup by prefix/name (DXCCData exists but unwired) | high | M | ✅ done ("Look up DXCC entity" on MUFView) |
| 23 | Pass Progression | Restore per-day grouping with weekday/date/pass-count row labels | high | M | ✅ done |
| 24 | Astronomy | Add Jupiter 14-day Io-source storm windows table | high | M | ✅ done (CML/Io phase + 14-day windows) |
| 25 | 3D Globe | Add playback animation (Play/Stop + 10x/60x/300x/1800x speed) | high | M | ✅ done |
| 26 | Mutual Windows | Add all-favorites scope mode merging results chronologically | high | M | ✅ done |
| 27 | Transits | Add export/share action and auto-recompute on picker change | high | S | ✅ done |
| 28 | Sites | Add CSV export and inline primary-site rename to SitesView | high | M | ✅ done |

## Cross-cutting themes

- ✅ **Shared polar-plot component lacks 8-point compass and elevation-ring labels** — DONE (Components.swift PolarSkyPlot now draws NE/SE/SW/NW + 0/30/60° ring labels).
- **Missing per-row severity / quality color coding** — Many screens display data rows in a single monochrome style even though the desktop applies traffic-light coloring (green good / amber warn / red bad) driven by a severity or quality field. In several cases the severity integer is computed in the engine but discarded before the view layer (Propagation, Space Wx). This removes the at-a-glance operational scan the desktop relies on. Consider adding a severity field to the shared row/LabeledContent rendering.
- **Fleet-wide / all-favorites visualizations re-scoped to single satellite** — The signature desktop concept of showing every favorited satellite at once was narrowed to the single selected satellite on multiple screens: Home overhead-now/next-passes/world-map, Sky Radar live sky, Mutual all-favorites scope, Sky Map favorites overlay, and Globe favorite footprints/labels/palette. The engine already computes per-favorite look angles; the gap is multi-entity rendering and scope toggles.
- **Missing summary / count / status lines after computation** — The desktop shows a one-line summary after most computations (result counts, totals, computed DX coords, provenance/stats). The iOS ports frequently omit these, forcing users to count rows or losing transparency about what a filter/scan produced. Nearly all are S-effort text additions.
- **Per-screen export / report actions missing (export exists elsewhere or not at all)** — Several feature screens have no Share/CSV/PDF affordance even though the desktop offers a save-report dialog, and in some cases the export capability already exists in ExportService/OrbitExportService but is only wired to a different screen. Surfacing a ShareLink on each screen is mostly S/M effort.
- **Multi-tab hub screens flattened, dropping whole tabs whose engine already exists** — Orbital Analysis (11 tabs to 1 flat scroll) and Satellites (3 tabs to 1 list) lost large surface area. Critically, most of the underlying computations (j2Rates, betaAngle, equatorCrossings, dopplerFrequencies, whats-up scan, by-type grouping) are already implemented in the engine layer — the work is re-adding tabbed navigation and wiring existing values into views, not new math.
- **Lists/results silently truncated by hardcoded caps** — Several screens cap displayed or fetched results well below what the desktop shows: AMSAT recent reports prefix(30) vs 200 fetched, Sky-at-a-Glance passes prefix(4) per satellite, Pass Progression prefix(30) of up to 100 and maxCount:100 vs 2000, eclipse days clamped to 30. Users see a fraction of available data with no pagination or indication.
- **Hardcoded parameters that were user-configurable pickers on desktop** — Multiple screens replaced desktop radio-button/combobox controls with fixed values: Exports step-size/time-span/visible-only, Planning twilight threshold and standard magnitude, min-elevation presets on Passes/Pass-Progression, Sky Radar time-window, min-elevation ceiling capped at 45 vs 89 in Settings. Restoring the pickers is mostly S-effort.

## Per-screen parity

| Screen | Parity | Gaps |
|--------|--------|------|
| Orbital Analysis | 28% | 13 |
| Sky Radar | 32% | 6 |
| Home | 38% | 7 |
| Pass Progression | 38% | 9 |
| Satellites | 42% | 8 |
| Track | 52% | 8 |
| Mutual Windows | 52% | 6 |
| Sky Map | 52% | 6 |
| Next Passes | 58% | 8 |
| OSCARLOCATOR Sim | 62% | 11 |
| Learn | 62% | 12 |
| Pass Detail | 68% | 4 |
| 3D Globe | 68% | 9 |
| MUF / HF Prop | 68% | 5 |
| Sky at a Glance | 72% | 5 |
| Ground Track | 72% | 5 |
| Graphing Calc | 72% | 4 |
| References | 72% | 8 |
| Sun / Moon | 72% | 7 |
| Space Wx | 72% | 6 |
| Planning | 72% | 10 |
| New Launches | 72% | 6 |
| Sites — Observer Locations & Comparison | 72% | 4 |
| Settings | 72% | 5 |
| Astronomy | 78% | 4 |
| Sun/Moon Transits | 78% | 4 |
| Workable | 78% | 4 |
| Propagation (HF / 6 m operating outlook) | 78% | 4 |
| Orbital Zones | 82% | 4 |
| AO-7 Mode | 82% | 4 |
| Activations / QRZ | 82% | 4 |
| Exports | 82% | 7 |
| AMSAT Status | 84% | 3 |
| EME — moonbounce planning | 84% | 4 |
| Illumination | 88% | 4 |
| Radio — Link Budget & Doppler Playbook | 88% | 5 |
| Tiny BASIC | 88% | 5 |
| Celestial (Bodies & EME) | 90% | 4 |
| Tools | 91% | 8 |
| Orbital History | 93% | 3 |
| Conjunctions | 97% | 3 |
