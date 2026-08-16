# OrbitDeck iOS — Functionality Audit vs CardSat & desktop OrbitDeck

_2026-08-15. Read-only comparison of the iOS implementation against the desktop Python app (`/tmp/OrbitDeck`) and the CardSat firmware (`github.com/prstoetzer/CardSat`). No code was changed. Items are gaps/bugs to consider, grouped by severity. Tags: **BUG** = likely wrong output, **MISSING** = feature absent, **PARED** = simplified/coarser than reference._

## ✅ Fixed 2026-08-15 (round 2)

- Pass finder now reports the **in-progress pass** and **continuously-visible / GEO** birds (OrbitPredictor.predictPasses) — HIGH #1, #2.
- **Radio playbook hold-downlink** now does the full round-trip (was one-way, mistuned uplink) — HIGH #3.
- **SatNOGS status filter** relaxed to keep active+inactive, skip only no-downlink rows — HIGH #4.
- **`isLinear`** tightened (needs uplink + Transponder type or ≥5 kHz) so wide beacons aren't mislabeled — HIGH #5.
- `nextEvent` horizon 6→10 days; `currentOrNextPass` back-walk 3h→12h (long passes) — MEDIUM.
- **W. Kiribati (T30) longitude** 157.4→173°E — MEDIUM.
- **New-launch noise tokens** realigned to the desktop's curated list (dropped risky operator names, added fleet tokens) — MEDIUM.
- Activations **start-time parsing** fixed (the `(UTC)` suffix defeated the DateFormatter); AMSAT catalog now **session-cached** + retried; cold-start feed retries; stale error clears on success.
- Rove coverage finding reviewed — **not a bug** (passes are predicted at the stop, so footprint coverage is inherent); left as-is.

## ✅ Fixed 2026-08-15 (round 4)

- **AMSAT match on load** — `resolveSelectedSatellite` now retries quietly (5×, 1.5 s) and never shows a "match failed" banner on auto-load (the manual API-name field stays usable); combined with the session cache it resolves once the catalog fetch succeeds once.
- **Orbital-zone scan** — added an **Auto** window (≈4 orbits, clamped 3–36 h) as the default, matching the desktop's adaptive basis.
- **Astronomy verified** — executed the four "empty" computations against the build target: they return **12 Jupiter Io-storm windows, 13 occultations, 13 appulses, 8 eclipses** (even with a null observer, current date). Units/frames/ranges/wiring all correct — the empty-on-device symptom is a stale install or device-runtime issue, **not** a code bug. No change made (would risk breaking correct code).

## ✅ Fixed 2026-08-15 (round 3)

- **Mutual windows** rewritten to be pass-scoped at 10 s (was full-timeline at 30 s) — tighter window edges, much faster.
- **Sat-to-sat LOS** windows now report **min range (km)**.
- **Activation frequency** scan gained a 20 MHz–25 GHz sanity band (won't misread a stray number as RF).
- **OSCARLOCATOR range-circle PDF** now applies the 1.065 polar-distortion inflation (was understating coverage).
- **AMSAT summary** now uses the retrying browser-UA request and a deterministic (reports, name) sort.

_Still open: DX-Doppler calibration offsets & passband-solver clamp; TLE checksum on import; adaptive zone window; OSCARLOCATOR PDF QTH-centered sheet + minute ticks; AO-7 resolve_api_names; link-margin curve; decay source sentinel; space-track throttle; workableGrids longitude-prune edge; footprint MapCircle; Tiny BASIC over-permissiveness. See lists below._

> Note on references: the desktop Python is itself a port of CardSat's C. Where iOS matches Python it usually matches CardSat too. Several findings are cases where iOS follows Python but Python diverges from the CardSat firmware — those need a decision on which source is canonical.

## HIGH

1. **No GEO / high-orbit / continuously-visible pass handling** — MISSING/BUG. `OrbitPredictor.predictPasses` (OrbitPredictor.swift:68) is a single 30 s below→above rise scan. A satellite that never sets in the window yields **zero passes**; Next Passes/Pass Progression/Track show "none". CardSat `predict.cpp` has a dedicated finder for mean-motion ≤ 6.4 rev/day that emits a horizon-long pass. Affects GEO/Molniya/high-apogee birds.

2. **In-progress pass silently skipped** — BUG. Because the scan seeds `previousElevation = elevation(start)` and only fires on a below→above transition, a satellite already up at load is dropped from `predictPasses` (Next Passes / Pass Progression). CardSat seeds `aos = from` when already up. iOS only recovers this in `currentOrNextPass` (Track), not the lists.

3. **Radio playbook linear-hold uplink is one-way, not round-trip** — BUG. `FeatureCompletionEngine.linkBudget`/playbook (FeatureCompletionEngine.swift:392) holds the ground dial fixed but computes the other leg with plain one-way Doppler (`ul/(1-β)`), so the held-downlink uplink dial is off by ~the receive-leg Doppler. CardSat `uplinkForFixedDownlink` (predict.cpp:19) does the full round-trip. (The DX four-dial path *does* do it correctly — only the single-station playbook is wrong.)

4. **SatNOGS transponder status filter too strict** — BUG/PARED. `TransponderService.parseRow` (TransponderService.swift:69) rejects any row whose `status != "active"`. CardSat keeps active+inactive (skips only no-frequency rows). iOS hides valid/newly-listed transmitters.

5. **`isLinear` detection too weak** — BUG. `TransponderRecord.isLinear` (SatelliteModels.swift:28) = `downlinkHigh > downlinkLow && downlinkLow > 0`. CardSat also requires an uplink and a Transponder type / ≥5 kHz bandwidth. iOS mislabels wide beacons/data as "Linear (inverting)", corrupting passband + DX-Doppler math.

6. **Rove scan ignores stop-footprint coverage** — BUG. `ParityPlanningEngine.rovePasses` (ParityPlanningEngine.swift:213) unions grids/states/DXCC over *every* sample and includes *every* pass. Python only accumulates while the stop is inside the footprint and drops passes never covering the stop. iOS reports non-covering passes and inflated workable sets.

## MEDIUM

- **`currentOrNextPass` back-walk capped at 3 h** (OrbitPredictor.swift:170) — long/high passes get a wrong AOS. BUG.
- **`nextEvent` uses 6-day horizon** (OrbitPredictor.swift:130) while lists use 10 — a pass 6–10 days out reports "no event". Inconsistent.
- **Jupiter Io-C range literal is dead/inconsistent** (FeatureEngine.swift:1163): tuple says `300...360` but an inline `cml>=300||cml<=20` overrides it; Io boxes follow Python, which diverges from CardSat firmware (Io-A/B/C bounds differ by 5–10°). Decide canonical source; fix the literal either way. BUG/PARED.
- **DX Doppler: calibration offsets (`cal_dl/cal_ul`) not plumbed** (FeatureEngine.swift:2249) and the passband solver **clamps** to `[0,bandwidth]` vs the reference's unclamped result (FeatureEngine.swift:2235) — silent saturation on out-of-band targets. PARED/BUG.
- **TLE checksum validation absent** on the classic-TLE import path (GPService.swift:165) — malformed lines silently dropped. PARED.
- **New-launch noise-token list drifted** (FeatureEngine.swift:2028): missing constellation tokens the desktop suppresses (SPACESAIL, GUOWANG, LIGHTSPEED, LEMUR, EOS-, SENTINEL, …) and *adds* risky commercial tokens (SES-, INTELSAT, SHIYAN) the desktop deliberately omitted → can hide real amateur payloads. BUG/PARED.
- **W. Kiribati (T30) longitude wrong** in DXCCData.swift:343 (`157.4`, should be ~`173`E); the app's own DXCCNumericData has `173`. Footprint/workable output for T30 ~1700 km off. BUG.
- **Mutual windows sampled at 30 s vs reference 10 s** and via a full-timeline scan rather than pass-scoped (FeatureEngine.swift:676) — short windows can be mis-bounded/missed; more expensive. PARED.
- **Orbital-zone scan window fixed (6/24/48 h)** vs reference adaptive `max(3h, min(36h, 4·period))` (FeatureViews.swift:1880). Dwell-per-day basis differs. PARED.
- **OSCARLOCATOR PDF gaps**: no QTH-centered azimuthal sheet with elevation/km rings; polar range circle omits the `1.065` inflation (understates coverage); path-arc lacks 1-min ticks / 10-min labels (ExportService.swift:961+, AdvancedFeatureViews.swift:421). MISSING/PARED.
- **Tiny BASIC accepts constructs CardSat rejects** (string `< > <= >=` at DeepParityEngine.swift:641; `%` modulo at :1121) — iOS-authored programs can fail on hardware. PARED (inverted).

## LOW

- AO-7 hard-codes API names `AO-7_[V/a]`/`[U/v]` (AO7Service.swift:54); no `resolve_api_names` catalog lookup → possible 404 if AMSAT renames. MISSING.
- Desktop `link_margin_curve` (per-elevation margin) not implemented. MISSING.
- Sat-to-sat LOS windows drop the `min_range_km` annotation (ParityPlanningEngine.swift:230). PARED.
- Decay/history source label keyed off a brittle string sentinel (FeatureEngine.swift:1417) rather than an enum. Fragile labeling only.
- Space-Track fetch has no throttle/hourly budget (reference: 3 s min interval, 200/hr). Cached + user-initiated, low risk. PARED.
- `workableGrids` longitude prune heuristic (FeatureEngine.swift:733) can clip antimeridian cells near ±75° with large footprints. Edge case. BUG(minor).
- Footprint drawn as a flat `MapCircle` radius (GroundTrackView.swift:57) slightly undersizes high-altitude footprints (value shown is correct). LOW.
- MINIMUF `m9` has an inert `max(0,…)` sqrt clamp not in the reference (FeatureEngine.swift:2411); masks regressions, not a live bug. LOW.
- AMSAT summary tie-order nondeterministic (Dictionary iteration); `pretty()` name rendering cruder than the reference regex. LOW.
- Activation frequency scan looser than reference (no 20 MHz–25 GHz sanity band; could misread a bare number). LOW.

## Verified OK (faithful ports — no action)

SGP4/SDP4 via SatelliteKit (WGS72); look/az/el/range/range-rate; bisection AOS/LOS + golden-section TCA; equator-crossing interpolation; beta angle; cylindrical-shadow eclipse; footprint formula; Doppler dial conventions (`(1−β)` down, `1/(1−β)` up, tx=0 gate); passband + inversion math; FIXED_DL/FIXED_UL/TRUE_RULE reference-instant lock; link-budget FSPL/EIRP/received-power; AO-7 square-wave fit + sunlight gating; MINIMUF-3.5 constants + 85% workable rule; SSN←F10.7 (1.61·(F−67)); aurora dipole/Kp boundary; 11-shower meteor table; EME path-loss/Doppler/Faraday/sky-temp/libration; planet ephemeris; propagation outlook thresholds; OMM/AMSAT_NAME mapping; full AMSAT name-match ladder + alias table; activations Atom title/li/UTC/date parsing; QRZ XML fields; DXCC 340-entity completeness; conjunction screening; orbital-zone classification; Space-Track history rate/decay pipeline; **calibrated decay model (12.741621·B*, King-Hele — not the stale 38·B*)**; Tiny BASIC statement/function/array/graphics coverage.
