# OrbitDeck for iOS

A comprehensive amateur-radio satellite tracker for iPhone and iPad. OrbitDeck computes passes, Doppler, look angles, footprints and link budgets from live orbital elements, and adds orbital analysis, live space weather, and the classic OSCARLOCATOR tracking overlays.

**Website:** <https://orbitdeckios.n8hm.radio> · **Docs:** <https://orbitdeckios.n8hm.radio/documentation.html> · **Privacy:** <https://orbitdeckios.n8hm.radio/privacy.html>

OrbitDeck is a companion to the OrbitDeck desktop app and CardSat by Paul Stoetzer, N8HM.

## Features

- **Track & predict** — live look angles, range/range-rate, sub-point and footprint; next-pass predictions with elevation profiles colored sunlit/eclipse; ground-track map (optionally every favorite's footprint); all-sky radar; 3D globe with a DX-station footprint for mutual visibility; polar sky plot with a star field; a daily schedule of every favorite's passes; a KlaTrack-style pass timeline on Home; one color per satellite throughout.
- **Automatic satellite switching** — SatPC32-style priority list (up to 9 satellites) with switch-in and take-over elevations, finish-current-pass and pause-after-manual-pick options, and a simulated 12-hour plan. Home, rig control and the rotator follow the selection.
- **Live Activity & Dynamic Island** — the next priority switch or favorite pass with AOS/LOS countdowns; it carries the next few passes and refreshes in the background so it stays current while OrbitDeck is closed, with an optional scheduled start for the next pass (iOS 26+).
- **Rig control (CAT)** — Doppler-tune your transceiver over a BLE serial adapter (Icom CI-V, Yaesu, Kenwood — including the TS-2000/TS-790 in satellite mode), the built-in Bluetooth of the IC-705/IC-905, an Icom network (RS-BA1) connection over Wi-Fi, or a Hamlib `rigctld` server.
  - **Station setups:** one full-duplex radio, split VFO on one radio for same-band birds, a single leg, or two radios (satellite rigs can be one leg of a two-radio station).
  - **Modes:** chosen from the transponder's modulation; SSB or CW on linear transponders; narrow FM (FM-N) on FM birds; data sub-modes (USB-D/LSB-D, FM-D, PKT) for FT4 and packet; per-satellite CTCSS.
  - **Operating:** live tune modes (full, downlink only, uplink only, hold), receive-only/beacon handling and a one-tap Beacon button, an engaged-satellite lock, Stop all, a CAT monitor and a guided self-test.
  - Configured in Settings, controlled on Home. Bluetooth Classic (SPP) adapters are not supported on iOS. A known-good DIY BLE&nbsp;↔&nbsp;CI-V bridge is [OrbitLinkS3](https://github.com/prstoetzer/OrbitLinkS3) on an M5Stack M5StickS3.
- **Rotator control** — steer an az/el rotator over a BLE serial adapter (GS-232 incl. azimuth-only, Easycomm I/II/III, SPID Rot2Prog, SAEBRTrack) or the network (rotctld over TCP, PstRotator over UDP, OZ9AAR URC over TCP/JSON).
  - **Tracking:** pre-position before AOS, slew lead, park on LOS, flip mode held for the whole pass, 0–360 / ±180 / 0–450° ranges, alignment offsets, magnetic correction.
  - **Hands-on:** manual jog/go-to/stop, position read-back with stall warning, self-test and monitor, and Sun/Moon/fixed-bearing targets for sun-noise checks and EME.
- **rigctld / rotctld servers** — let Gpredict, SatPC32, WSJT-X or a logger on your LAN drive or read the radio and rotator through OrbitDeck's connection (off by default; network PTT is a separate opt-in with a keyed-time limit).
- **Digital modes & audio** — over a USB audio interface or an Icom network-audio radio:
  - **Pass recording.**
  - **CW decoder:** automatic tone tracking, adaptive speed, prosigns, tap-to-log callsigns.
  - **Packet / APRS:** built-in 1200 and 9600 (G3RUH) baud modems, a BLE KISS TNC or KISS over TCP (Direwolf, soundmodem); APRS messages (with retries) and position/status beacons through satellites and the ISS, gated by minimum elevation; objects, items, weather and third-party packets; heard-station map with symbols; alerts and a watch list; a saved per-pass log with TNC2/CSV export; an opt-in receive-only RF → APRS-IS satgate; automatic QSO logging.
  - **SSTV:** Martin, Scottie (incl. M3/M4/S3/S4), Robot and PD modes; Doppler-aware auto-tune, damaged-header fallback, line repair, combined copies, a gallery with re-decode, auto start/stop by elevation.
  - **Full-duplex FT4** on a linear transponder: Doppler-corrected, late start, wait-and-pounce, CQ block list, signal subtraction and deep re-decode, DT column, new-call/grid highlighting, a waterfall, a Tune button, a TX watchdog, automatic transponder calibration from your own signal, PTT over CAT. Not offered on FM-only transponders.
  - **Audio health:** stalled or silent input is detected and recovered.
  - FT4 uses the MIT [ft8_lib](https://github.com/kgoba/ft8_lib). FT4 is ~100% duty cycle — limit power.
- **Logging, LoTW & awards** — on-device QSO log with a Home quick-log card and voice memos that become QSO entries.
  - **Uploads:** LoTW, with the `.tq8` signed on device from your callsign certificate and a full DXCC → subdivision station-location picker plus IOTA; Cloudlog/Wavelog; re-send after edits.
  - **Awards:** satellites, VUCC grids, WAS and DXCC, worked and LoTW-confirmed.
  - **Per-QSO data:** DXCC entity, QRZ name and state fill, RST by mode.
  - **Import and export:** ADIF (importing a LoTW download marks matching QSOs confirmed); PDF log and award reports.
- **Work the birds** — four-dial DX Doppler and a single-station RX/TX Doppler playbook; a no-CAT hold/tune calculator; per-satellite (and per-transponder) calibration with a bulk Calibrations screen and CSV import/export; link budget with a per-elevation margin curve; SatNOGS transponder database; AO-7 mode timer; mutual-visibility windows.
- **Activations & status**
  - **Activations:** upcoming satellite activations from hams.at with a "can I work it?" check, reminders, your own entries and an offline copy; post your own activation to hams.at.
  - **AMSAT status:** the status board with heard marks in the Satellites list, and one-tap attributed status reporting from Home.
  - **Nearby & DX:** APRS-IS, a DX cluster and ADS-B from your own receiver.
  - **Lookups:** QRZ XML callsign lookup.
- **Plan & analyze**
  - **Orbits:** orbital elements and derived quantities (J2 rates, beta angle, eclipse fraction, LTAN), element-set age and launch siblings; equator crossings; Sun/Moon transits; illumination; orbital zones; state-vector → GP element recovery.
  - **Conjunctions:** conjunction and debris-group screening.
  - **Sky:** comet positions.
  - **Workable areas:** workable states and DXCC by real boundaries, with export.
  - **Weather:** cloud cover on visible passes.
- **Station & grids** — fixed site or follow-the-device location; Maidenhead entry; secondary sites; VUCC grid-line and corner recognition; a live Grid Finder (with speed and course); a location converter (grid, DMS, Plus Code, UTM, MGRS, USNG) and grid distance/bearing (short and long path) that can point the rotator.
- **Propagation & space weather** — MUF/HF path tool and a 6 m/HF outlook; solar flux, Kp/A (NOAA SWPC) and sunspot number (hamqsl.com/N0NBH) with trend deltas and aurora likelihood.
- **OSCARLOCATOR** — on-screen simulator (polar and QTH-centered) with minute-tick ground tracks, printable PDF overlays, and a Reference Orbits schedule.
- **Bench tools, learning & housekeeping**
  - **Calculators:** 60+ for antennas, feedline, RF, link and orbits; a scientific calculator; a graphing calculator with roots, intersections, dy/dx, integrals and CSV import.
  - **Other tools:** Tiny BASIC and DXCC lookup.
  - **Learning:** Learn lessons and References, including orbit types, Fox CubeSat anatomy, CubeSat Simulator and a worldwide band plan.
  - **Housekeeping:** Notes (in the Files app), in-app Help, a station readiness checklist, report exports, backup & restore, and factory reset.

## Requirements

- iOS / iPadOS 17 or later (iPhone and iPad)
- A current Xcode (the app target uses Swift 6 language mode)
- [SatelliteKit](https://github.com/gavineadie/SatelliteKit) for SGP4/SDP4 propagation (resolved via Swift Package Manager)

## Build

1. Open `OrbitDeckIOS.xcodeproj` in a current Xcode on macOS.
2. Let Swift Package Manager resolve SatelliteKit.
3. Select an iPhone or iPad simulator (or a device) running iOS 17+.
4. Build and run the **OrbitDeckIOS** scheme (it also builds the `OrbitDeckWidgets` Live Activity extension).

Location, notifications, the microphone, the local network and the Keychain are used only by their associated, user-initiated features.

The unit tests live in `OrbitDeckIOSTests/` (Swift Testing). The test target currently needs the ft8_lib header search path (`$(SRCROOT)/OrbitDeckIOS/DigitalModes/ft8_lib`) added before it builds.

## Data sources

OrbitDeck retrieves publicly available data and identifies itself politely:

| Service | Used for |
|---------|----------|
| CelesTrak | General Perturbations (GP) orbital elements, New Launches, debris groups |
| AMSAT | Daily bulletin GP feed; satellite status (status.amsat.org) |
| NOAA SWPC | Solar flux, planetary Kp and A index (and sunspot number as a fallback) |
| hamqsl.com (N0NBH) | Observed sunspot number (the amateur-community reference) |
| SatNOGS | Transponder database and new-launch discovery |
| hams.at | Upcoming satellite activations; posting your own alerts with your API key (optional) |
| Open-Meteo | Weather and cloud cover for planning (location rounded to about 1 km) |
| APRS-IS (optional) | Receive-only nearby APRS stations, logged in with your callsign; if you turn on the satgate, packets heard over the satellite are uploaded with your callsign and passcode |
| DX cluster (optional) | DX spots from a cluster you choose |
| ADS-B (optional) | Aircraft from your own receiver on your network |
| QRZ (optional) | Callsign lookup and name/state fill, if you provide credentials |
| Space-Track (optional) | Archival elements for Orbital History, if you provide credentials |
| LoTW / Cloudlog (optional) | Uploading your QSOs, if you configure them |

OrbitDeck honors CelesTrak's usage policy — at most one request per dataset every two hours, with back-off on rate-limit responses — so normal use will not get your address blocked. Cached data keeps core tracking working offline.

## Privacy

OrbitDeck does not collect, store, or transmit personal information to the developer, and contains no advertising or third-party analytics or tracking. Location is used on your device; when you view weather, an approximate (about 1 km) position is sent to Open-Meteo. Optional passwords, API keys and your LoTW certificate are stored in the iOS Keychain. See the [privacy policy](https://orbitdeckios.n8hm.radio/privacy.html).

## Repository layout

| Path | Contents |
|------|----------|
| `OrbitDeckIOS/` | The iOS app sources (SwiftUI) |
| `OrbitDeckIOS.xcodeproj` | The Xcode project |
| `OrbitDeckWidgets/` | The widget extension (next-pass Live Activity / Dynamic Island) |
| `OrbitDeckIOSTests/` | Unit tests (Swift Testing) |
| `docs/` | The GitHub Pages website (served at orbitdeckios.n8hm.radio) |
| `fastlane/` | App Store screenshot automation configuration |
| `RELEASE_NOTES-*.md` | Per-version release notes; `RELEASE_NOTES-1.1.md` is the running log for 1.1 |

SGP4/SDP4 propagation is provided by [SatelliteKit](https://github.com/gavineadie/SatelliteKit), resolved as a Swift Package dependency at build time (not vendored in this repository).

## Contributing

Use **American English** throughout: in the app's text, code comments, documentation and the website (color, center, behavior, canceled, catalog, analyze, …). Apple API names keep their own spelling (for example `isCancelled`).

## Support AMSAT

Please consider joining or donating to [AMSAT](https://www.amsat.org) — the Radio Amateur Satellite Corporation — a volunteer, member-supported non-profit that designs, builds and helps launch the amateur-radio satellites OrbitDeck is made to track.

## License and credits

© 2026 Paul Stoetzer, N8HM. [SatelliteKit](https://github.com/gavineadie/SatelliteKit) is a separate Swift package under its own license. Other third-party code and data (ft8_lib, d3-celestial constellation lines, Natural Earth, the Yale Bright Star Catalog, Open-Meteo) are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and in the app under Settings → About → Acknowledgments.

### Contributors

Thank you to everyone whose pull requests have been merged into OrbitDeck:

- **Filip Melik** ([@filipmelik](https://github.com/filipmelik))
  - [#5](https://github.com/prstoetzer/OrbitDeckiOS/pull/5) — Next Passes screen interaction fixes
  - [#8](https://github.com/prstoetzer/OrbitDeckiOS/pull/8) — Home screen fixes: stale data refreshed on return from the background, and in-progress passes moved to Overhead Now with their LOS time
  - [#9](https://github.com/prstoetzer/OrbitDeckiOS/pull/9) — Native Bluetooth CAT for the IC-705 and IC-905 (sign-in protocol behavior per K7MDL2's IC-705 BLE example)

Contributions are welcome — open an issue or a pull request.
