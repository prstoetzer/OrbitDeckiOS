# OrbitDeck for iOS

A comprehensive amateur-radio satellite tracker for iPhone and iPad. OrbitDeck computes passes, Doppler, look angles, footprints and link budgets from live orbital elements, and adds orbital analysis, live space weather, and the classic OSCARLOCATOR tracking overlays.

**Website:** <https://orbitdeckios.n8hm.radio> · **Docs:** <https://orbitdeckios.n8hm.radio/documentation.html> · **Privacy:** <https://orbitdeckios.n8hm.radio/privacy.html>

OrbitDeck is a companion to the OrbitDeck desktop app and CardSat by Paul Stoetzer, N8HM.

## Features

- **Track & predict** — live look angles, range/range-rate, sub-point and footprint; next-pass predictions with elevation profiles; ground-track map; all-sky radar; 3D globe and polar sky plot.
- **Work the birds** — four-dial DX Doppler and a single-station RX/TX Doppler playbook with per-radio calibration; link budget with a per-elevation margin curve; SatNOGS transponder database (two-way transponders first); AO-7 mode timer; mutual-visibility windows.
- **Plan & analyze** — orbital elements and derived quantities (J2 nodal/apsidal rates, beta angle, eclipse fraction, LTAN); equator crossings; Sun/Moon transits; illumination; orbital zones; conjunctions; workable-grid discovery; state-vector → GP element recovery (TEME or J2000) with export.
- **Station & grids** — fixed site or follow-the-device location; enter your station by latitude/longitude or Maidenhead grid square; save secondary sites (including from your current GPS position); VUCC grid-line and corner recognition per ARRL rules.
- **Propagation & space weather** — MUF/HF path tool and a 6 m/HF operating outlook; live NOAA space weather (solar flux, sunspot number, planetary Kp and A index) with aurora likelihood.
- **OSCARLOCATOR** — on-screen simulator (polar and QTH-centered) with minute-tick ground tracks, printable PDF overlays, and a Reference Orbits schedule.
- **Bench tools** — 60+ calculators for antennas, feedline, RF, link and orbits; a receipt-tape scientific calculator with RF/orbit functions and metric-prefix literals; a graphing calculator with trace, roots, integral, table and CSV export; grid ↔ lat/lon converter, Tiny BASIC and DXCC lookup.

## Requirements

- iOS / iPadOS 17 or later (iPhone and iPad)
- Xcode with Swift 6
- [SatelliteKit](https://github.com/gavineadie/SatelliteKit) for SGP4/SDP4 propagation (resolved via Swift Package Manager)

## Build

1. Open `OrbitDeckIOS.xcodeproj` in a current Xcode on macOS.
2. Let Swift Package Manager resolve SatelliteKit.
3. Select an iPhone or iPad simulator (or a device) running iOS 17+.
4. Build and run the **OrbitDeck** scheme.

Location, notifications and Keychain are used only by their associated, user-initiated features.

## Data sources

OrbitDeck retrieves publicly available data and identifies itself politely:

| Service | Used for |
|---------|----------|
| CelesTrak | General Perturbations (GP) orbital elements |
| AMSAT | Daily bulletin GP feed and satellite status |
| NOAA SWPC | Solar flux, sunspot number, planetary Kp and A index |
| SatNOGS | Transponder database |
| hams.at | Upcoming satellite activations |
| QRZ (optional) | Callsign lookup, if you provide credentials |
| Space-Track (optional) | Archival elements for Orbital History, if you provide credentials |

OrbitDeck honors CelesTrak's usage policy — at most one request per dataset every two hours, with back-off on rate-limit responses — so normal use will not get your address blocked. Cached data keeps core tracking working offline.

## Privacy

OrbitDeck does not collect, store, or transmit personal information to the developer, and contains no advertising or third-party analytics or tracking. Location is used only on your device; optional QRZ/Space-Track passwords are stored in the iOS Keychain. See the [privacy policy](https://orbitdeckios.n8hm.radio/privacy.html).

## Repository layout

| Path | Contents |
|------|----------|
| `OrbitDeckIOS/` | The iOS app (SwiftUI) and its Xcode project |
| `docs/` | The GitHub Pages website (served at orbitdeckios.n8hm.radio) |
| `fastlane/` | App Store screenshot automation configuration |

SGP4/SDP4 propagation is provided by [SatelliteKit](https://github.com/gavineadie/SatelliteKit), resolved as a Swift Package dependency at build time (not vendored in this repository).

## Support AMSAT

Please consider joining or donating to [AMSAT](https://www.amsat.org) — the Radio Amateur Satellite Corporation — a volunteer, member-supported non-profit that designs, builds and helps launch the amateur-radio satellites OrbitDeck is made to track.

## License and credits

© 2026 Paul Stoetzer, N8HM. [SatelliteKit](https://github.com/gavineadie/SatelliteKit) is a separate Swift package under its own license.
