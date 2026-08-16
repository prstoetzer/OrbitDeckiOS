# OrbitDeck iOS/iPadOS porting status

Target: native SwiftUI, iOS/iPadOS 17+, current native port version **0.9.7**.

Status language:

- **Functional parity**: the desktop workflow and calculations are available natively, although layout may be adapted for iPhone/iPad.
- **Deep functional parity**: the desktop workflow plus its specialist analysis/export/detail behavior has been ported and regression-tested on the portable host.

After the 0.9.7 destination-by-destination audit, there are **no known ordinary desktop feature gaps** in the 41-destination workflow set. A few desktop omnibus pages are intentionally decomposed into dedicated native destinations rather than duplicated inside one screen. Platform-only differences and Apple-SDK validation are listed separately below.

| Desktop destination | 0.9.7 status | Native implementation |
|---|---|---|
| Home | Functional parity | Live look, station, next pass and element summary |
| Track | Functional parity | Live polar position and tracking metrics |
| 3D Globe | Deep functional parity | Orthographic globe, follow/QTH/polar/free views, ±3 h scrubber, bundled offline coastlines, track/footprint, night shading and favorite markers |
| Sky Radar | Functional parity | Live polar sky display |
| Next Passes | Functional parity | Pass search plus operator-requested local alarms |
| Sky at a Glance | Functional parity | All-favorites pass forecast and longest quiet gap |
| Pass Detail | Functional parity | Next-pass polar path and TCA data |
| Ground Track | Functional parity | MapKit track, observer and current satellite |
| Pass Progression | Functional parity | Swift Charts elevation progression plus report output |
| Orbital Analysis | Functional parity across native destinations | Native analysis card now includes mean elements, derived orbit, J2 node/perigee rates, calibrated B*-lifetime readout and current geometry. Desktop omnibus pages for live position, next pass, ground track, Doppler, illumination/pass outlook and EQX are intentionally exposed as the dedicated Track, Passes/Pass Detail, Ground Track, Radio, Illumination/Pass Progression and OSCARLOCATOR/Exports destinations instead of duplicated. |
| Orbital History | Deep functional parity | Authenticated full-resolution Space-Track history/cache, fractional time-axis zoom/pan, value + rate plots, whole-record acceleration/jump analysis, archive-anchored decay, zoomed summary, raw CSV and printable PDF |
| Illumination | Deep functional parity | Live shadow/beta state, scrollable 30-day × 96-phase raster, 1/3/7/14-day orbit eclipse ephemeris, daily eclipse totals, CSV/PDF and 60-day raster report |
| Orbital Zones | Functional parity | SAA, belts, polar caps, eclipse; current state/dwell/refined windows |
| AO-7 Mode | Deep functional parity | Continuous-sunlight gating, 14/30/60-day AMSAT report window, weighted timer fit, time-to-switch, agreement, phase uncertainty and observed mode-change counts |
| Mutual Windows | Deep functional parity | Simultaneous home/DX visibility by grid or lat/lon plus printable table and paired polar sky plots |
| Sun/Moon Transits | Functional parity | Closest approaches and disk transits |
| Astronomy | Deep functional parity | All 8 desktop tabs: meteor showers, Jupiter, aurora, twilight, EME, occultations, appulses and eclipse planning; planning-precision contract retained |
| Sky Map | Functional parity | Sun, Moon, five planets, complete desktop cosmic-radio-source roster, cold-sky reference and selected satellite on the polar sky map |
| Conjunctions | Deep functional parity | Pair screening, 6/12/24 h horizons, threshold control, TCA/miss/relative-velocity detail, ±10 min separation curve, full-catalog neighborhood ranking and CSV/PDF awareness products |
| Workable | Deep functional parity | Live/next-pass unions for Maidenhead grids, US-state centroids and all 340 DXCC reference points |
| Radio | Deep functional parity | Shared upcoming-pass picker, AOS→LOS link-budget scrubber, editable ground/satellite assumptions, linear-passband position, 30/60/120 s Doppler playbook, fixed-uplink/fixed-downlink round-trip rules, passband plan, CSV and printable operating PDF |
| Planning | Deep functional parity | Work target, workable horizon, target search, visible passes, sat-to-sat LOS, rove, element trust/horizon mask and seven PDF report families |
| Tools | Deep functional parity | **56 native calculators; all 49 desktop registry entries represented**, plus native extras; full 340-entity DXCC lookup by prefix/name/ARRL code offline |
| Graphing Calc | Functional parity | Safe whitelisted expression evaluator, one/two traces and domain/fixed-y control |
| Tiny BASIC | Deep functional parity | CardSat numeric/string variables, mixed pre-run INPUT, anonymous/named arrays, text/math/geometry functions, complete 340-current-entity ARRL numerical DXCC bridge, pass/SATSEL/TXSEL host snapshots, sandboxed files, LPRINT, 240×135 graphics; **32-case gate with 13 real CardSat fixtures** |
| Activations / QRZ | Deep functional parity | hams.at feed/workability, mutual-window operating detail, dual sky tracks, four-dial DX Doppler and exact-current-plan CSV/PDF export; QRZ XML lookup |
| AMSAT Status | Functional parity | Board, recent reports and explicit-confirmation posting |
| OSCARLOCATOR Sim | Deep functional parity | Polar/QTH simulator, live/manual/next-pass EQX, persisted/shared lab orbit, A/B ghost comparison, guided challenges, glossary, save-to-catalog and three-sheet printable PDF |
| Learn | Deep functional parity | **22** interactive lessons, including six-element RAAN/perigee orientation, shared OSCARLOCATOR lab orbit and native four-page classroom PDF handout |
| References | Deep functional parity | **14** searchable tables including the complete 340-row DXCC entity reference-point table with ARRL numerical codes |
| Exports | Deep functional parity | Pass CSV/XLSX/ICS/JSON/PDF, alarms, comparison CSV, pass-card PNG, AOS/LOS/EQX/one-two-observer listings, 30/60-day OSCARLOCATOR Reference Orbits, full selected-satellite report with 60-day illumination + 30-day progression graphics, standalone illumination/progression/eclipses PDFs, favorites chronological report, saved-site comparison, mutual-window report, activation operating CSV/PDF, Celestial/EME/Conjunction/Radio/New-Launch specialist products |
| Sun / Moon | Functional parity | Live Sun/Moon az-el, phase/illumination and lunar distance |
| Celestial | Deep functional parity | Sun, Moon, planets, all desktop cosmic radio sources, cold-sky reference and selected-satellite az/el in polar/table views, with CSV/PDF sharing |
| EME | Deep functional parity | Desktop band picker; live Moon geometry; path degradation, Sun separation and ground-gain indication; per-band self Doppler/Faraday/sky temperature/libration/path loss; 90-day EME plan; common-Moon windows; CSV/PDF sharing |
| Space Wx | Functional parity | NOAA SWPC F10.7/SSN/Kp, reported daily planetary A where available with labeled Kp→ap fallback, and operating outlook |
| MUF / HF Prop | Functional parity | MINIMUF-3.5 world-region and direct-path calculations |
| Propagation | Functional parity | Day/night bands, geomagnetic/aurora/absorption, meteor and sporadic-E outlook |
| Satellites | Functional parity | Search/select/favorites, GP/TLE, persistent manual satellites/transponders |
| New Launches | Deep functional parity | User-initiated CelesTrak last-30-days × bulk SatNOGS discovery, noise filtering, add-to-favorites, persistent add-to-my-satellites for objects outside the current GP source with normal CelesTrak NORAD refresh, and CSV/PDF reporting |
| Sites | Functional parity | Persistent sites and multi-site pass comparison |
| Settings | Functional parity | Observer, Core Location, GP source, identity/QRZ and alarm preferences |

**Feature workflows represented: 41 of 41 destinations. Known ordinary desktop feature gaps after the 0.9.7 audit: 0.** 0.9.7 remains deliberately below 1.0 because source-level feature parity is not the same as device-release validation.

## 0.9.7 feature-completion additions

- **EME**: ports the desktop specialist physics and planning model: seven selectable operating frequencies, five-band comparison, self-echo Doppler, Faraday estimate, galactic-background temperature, libration spread, path degradation, Moon/Sun separation, ground-gain indication, 90-day planner and common-window exports.
- **Celestial / Sky Map**: adds Orion A, Centaurus A and Fornax A, the cold-sky reference and the selected satellite to the existing Sun/Moon/planet/radio-source model; adds Celestial CSV/PDF.
- **Conjunctions**: upgrades pair screening with detailed TCA geometry and a ±10-minute separation curve, scans the full loaded catalog for the neighborhood view, and adds pair/neighborhood export products. The screen remains explicitly an awareness tool, not collision-avoidance data.
- **Radio**: ports the desktop three-workflow operating screen—link budget, Doppler playbook and passband plan—with pass selection, AOS→LOS scrubber, adjustable assumptions, linear fixed-leg tuning rules and CSV/PDF output.
- **Illumination**: adds the desktop 30-day/96-phase raster and orbit-by-orbit/daily eclipse ephemeris with 1/3/7/14-day spans and CSV/PDF sharing.
- **New Launches**: closes the add-new-object path. A hit outside the current catalog can be persisted as an extra satellite, selected/favorited immediately, and refreshed by NORAD from CelesTrak during normal GP updates; scan results also gain CSV/PDF output.
- **AO-7**: adds the desktop 14/30/60-day report-fit window and time-to-switch/report/mode-change detail.
- **Orbital Analysis**: adds J2 node/perigee rates and the calibrated B*-anchored lifetime estimate while retaining the native decomposition of the desktop omnibus pages into dedicated destinations.

## Remaining non-feature work / intentional platform differences

1. **Full Xcode simulator/device build and Apple-SDK execution.** SwiftUI, UIKit, Charts, MapKit, Core Location, notifications, Keychain and the actual vector-PDF branches still require macOS/Xcode validation.
2. **Device/accessibility/privacy/App Store validation.** Test real notification delivery, Core Location permission flows, sharing, file-opening, rotation/size classes, VoiceOver/Dynamic Type and App Store assets/privacy declarations.
3. **Platform-only Tiny BASIC host values.** CardSat battery/heap/charging/GPS-device telemetry and its exact IGRF-14 field are not fabricated on iOS. Native magnetic/belt values remain explicitly planning-grade where the source model differs.
4. **Optional enhancements beyond desktop parity.** Authoritative astronomy cross-check services, additional external conjunction data sources, CAT/rotator hardware transports and other new integrations would be new features rather than gaps in the desktop port.

## Validation status

All **39 application Swift sources** parser-check and have matching PBX file references plus Sources-phase entries. Shared non-UI models, predictor, Feature/Utility/DeepParity/DXCC/Planning/Astronomy/world-map/feature-completion engines, relevant network services, XLSX writer and ExportService pass Swift 6 strict-concurrency type checking against a SatelliteKit-compatible API module. Tiny BASIC remains **32/32** with **13 real CardSat fixtures**.

The current-tree regression chain is green:

- 0.9.2: astronomy eclipse contacts/ground tracks/occultations and report path.
- 0.9.3: coastline dataset, Reference Orbits, physical OSCARLOCATOR and activation DX Doppler.
- 0.9.4: 340/340 DXCC numerical bridge and report families.
- 0.9.5: illumination/progression/mutual reports, activation exact-plan export and live BASIC host paths.
- 0.9.6: native XLSX, NOAA planetary-A parsing, Orbital History rate analysis and archive-anchored decay.
- 0.9.7: EME/Celestial roster, conjunction detail, Radio playbook/passband plan, satellite eclipse ephemeris and persistent extra-satellite construction.

Backward preference decoding remains green with the new optional extra-satellite field. `project.pbxproj`, version/User-Agent strings, source manifest and final ZIP are validated during packaging. A full Apple-SDK compile still requires Xcode on macOS; UIKit PDF branches are parser-reviewed and portable fallbacks are runtime-tested here, but actual Apple vector-PDF rendering is not claimed as executed.
