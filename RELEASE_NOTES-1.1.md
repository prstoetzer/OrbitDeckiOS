# OrbitDeck 1.1 — change log since 1.0 (working notes)

Running log of everything added or changed since **1.0 (18)**, the App Store release, for the 1.1 App Store notes and the website/documentation update. **The website (`docs/`) has deliberately not been updated yet** — do that when 1.1 is submitted. See "Website pages to update" at the end.

Builds so far: 1.1 (1) → 1.1 (4). Everything below is in `main`; the build each item landed in is shown in brackets.

---

## Highlights (for the App Store "What's New")

- **CW decoder** — copy Morse on the downlink with automatic tone tracking, adaptive speed, prosigns and tap-to-log callsigns. [4]
- **Packet / APRS** — built-in 1200 and 9600 baud modems, APRS messaging and beacons through satellites and the ISS, a map of heard stations, or a Bluetooth LE KISS TNC. [1–3]
- **Awards and a better log** — VUCC grids, WAS, DXCC and per-satellite totals; LoTW location picker for every entity LoTW supports; voice memos that become QSO entries; PDF log reports. [3]
- **Two-radio stations with satellite rigs**, a live tune-mode selector, Stop all, and rigctld/rotctld servers so desktop programs can share OrbitDeck's radio and rotator links. [3]
- **Automatic satellite switching** (SatPC32 style) with a KlaTrack-style pass timeline. [1]
- **Rotator**: manual control, position read-back, self-test, Sun/Moon aiming. [3]
- **Live Activity & Dynamic Island** for the next pass, now staying current while the app is closed. [1–4]
- **Planning extras**: weather and cloud cover on visible passes, activation reminders, backup & restore, in-app Help and a station readiness checklist. [3]

---

## Rig control (CAT)

- **IC-705 / IC-905 built-in Bluetooth** — connect without an adapter (contributed by Filip Melik, PR #9; sign-in per K7MDL2's IC-705 BLE example). [1]
- **Split-VFO Doppler on one radio** — VFO A = downlink, VFO B = uplink with SPLIT, for same-band birds (packet digipeaters, ISS APRS) and any non-satellite transceiver; researched per model (Icom, FT-817 family, FT-100, TS-2000/790). Same-band birds on MAIN/SUB rigs switch to split automatically for that pass. [1]
- **Satellite-aware modes** — receiver mode chosen from the transponder's modulation (SSTV/packet/FSK → FM, BPSK/FT4 → USB); narrow FM only where suitable; uplink mode from SatNOGS. [1]
- **CW on linear transponders** — SSB | CW switch on Home's Live Doppler card (also in CAT settings); both legs go to CW; quick-log logs CW/599. [2, moved to the Doppler card in 3]
- **Per-satellite CTCSS** — built-in tones for SO-50, AO-91, PO-101 and the ISS repeater, plus a per-satellite override; falls back to the global tone. [1]
- **Data mode for FT4 and packet** — USB-D/LSB-D and FM-D (Icom), PKT on the FT-817 family; requested per digital mode and per transponder. [1]
- **Satellite rigs as two-radio legs** — e.g. IC-821 on 2 m up + IC-705 on 10 m down for AO-7 Mode A. [3]
- **Live tune mode** on the Home rig card — Full (downlink-follow), Full (uplink-follow), Downlink only, Uplink only, Hold. [3]
- **Receive-only transponders/beacons** on Icom satellite rigs — satellite mode off and tuning on MAIN; a one-tap **Beacon** button. [3]
- **Engaged-satellite lock** — picking another satellite mid-pass asks before retuning the radio and moving the antenna (automatic switching still switches); shared rule for CAT and rotator. [3]
- **Stop all** — releases PTT, stops FT4/packet, disconnects CAT, parks the rotator. [3]
- **Passband-edge banner**, **CAT monitor** (per-frame trace) and **guided self-test**, **CAT rate floor** for slow serial rates, **tilt-to-tune** (optional). [3]
- **No-CAT HOLD/TUNE calculator** — hold one leg at a fixed dial (HT, FT-817) and read the other's corrected dial live.[3]; type the held dial in MHz, kHz or Hz with a live result and a keypad Done button [4]
- **Kenwood TS-590/590SG/890/990** as single-radio legs. [1]
- **rigctld** — VFO mode with `\chk_vfo` probe (avoids Hamlib retuning the wrong VFO on Icom sat rigs); split method kept as a fallback and for existing setups. [3]
- **Clean disconnect** — CTCSS off, Icom satellite mode off, back to MAIN/VFO A. [1]
- **Safety** — PTT refuses to key on a transponder with no uplink; two-radio BLE setup mistakes are caught before connecting (same adapter for both radios, missing device, Radio 2 not set up). [1, 3]
- Many CAT fixes from the OscarWatch cross-check (IC-9700 band exchange, FT-847 same-band hold, TS-2000 data mode, TH-D74/D75 stepping, FM-N filter bytes …). [1]

## Network servers

- **rigctld server** (TCP 4532) and **rotctld server** (TCP 4533) so Gpredict, SatPC32, WSJT-X or a logger on your LAN can read/drive the radio and rotator through OrbitDeck's link. Off by default. Network PTT is a separate opt-in (default off) with a 3-minute keyed limit and automatic unkey when the client drops. Foreground (or background-audio) only. [3]

## Rotator

- **Flip mode fixed** — decided once per real pass; no more flipping back mid-pass. [1]
- **Compass display** in ±180° mode; **GS-232 azimuth-only** controllers; **SPID** reply checks with retries. [1]
- **Manual control** — jog, go-to az/el, Stop, Park, resume tracking. [3]
- **Position read-back** with stall warning; **self-test**; **monitor**. [3]
- **Sun / Moon / fixed-bearing targets** (sun-noise G/T checks, EME); "point rotator" from the Grid distance tool. [3]

## Digital modes and audio

- **CW decoder** — automatic tone search (300–1,200 Hz) with AFC, 50/100/200 Hz filters, squelch, adaptive 5–50 WPM (or fixed) with Farnsworth handling, full ITU table + prosigns; spectrum strip (tap to tune), transcript with copy/share/timestamps, tappable callsigns → quick log. Runs alongside recording, FT4 and SSTV. [4]
- **Packet / APRS** — built-in AFSK 1200 modem and BLE KISS TNC (B.B. Link for the TH-D74/D75) [1]; UISS-style messages, per-satellite path/format, macros, PTT watchdog, timed beacon, heard-station list, automatic QSO logging when a two-way exchange completes [1]; **9600 baud G3RUH** modem, **APRS map** of heard stations with symbols, data mode [1].
- **FT4** — late start within 2 s of a slot, wait-and-pounce, CQ block list, remembered `<…>` callsigns, per-transponder echo calibration, missing-grid warning, more robust message parsing; Doppler hold only on the FT4 transponder. [1]
- **FT4 decoding** — signal subtraction with a second/third decode pass for weaker stations under strong ones (on by default); **Decode again (deep)** on the previous slot (button or long-press the waterfall: more candidates, 50 LDPC iterations, de-chirp grid for sliding uplinks), merged and tagged "deep"; DT column (WSJT-X convention) with an optional |DT| > 1.5 s filter. [4]
- **FT4 Band Activity** — shading for calls and VUCC grids not yet in the log, a "Target" tag for pounce targets, and an All / Me & my echoes filter. [4]
- **FT4 waterfall** — faster noise-floor tracking, 2–4 averaged FFT frames per line, slot lines with UTC labels, 12/24/48 s history. [4]
- **FT4 safety** — TX watchdog (default 6 min, 2–15) halts TX when nothing addressed to you is decoded; refuses to start on FM-only transponders (linear birds incl. AO-7 unaffected); courtesy warning when CAT reads RF power above ~30 W (CI-V, Kenwood, rigctld); **Tune** button (≤ 10 s carrier at the TX audio frequency). Sequencer fixes: a repeated RR73 after completion gets one more 73 without a duplicate log; a stray 73/RR73 from an unworked station no longer starts or logs a QSO. [4]
- **SSTV** — per-satellite expected modes and damaged-VIS fallback, Robot 36/72 guard, noisy-line repair, chroma smoothing, combined repeat copies, partial captures placed correctly, auto start/stop by elevation. [1]
- **SSTV Martin M3/M4 and Scottie S3/S4** (128-line variants), decoded from VIS. [4]
- **Screen stays awake automatically** while FT4, SSTV, packet, the CW decoder or a pass recording runs, on any screen; released when the last one stops (the Home opt-in is unchanged). [4]
- **Audio health** — detects a stalled or silent audio input, restarts capture, and warns on the FT4/SSTV/packet/recording cards. [1]

## Logging, LoTW and awards

- **Awards** — QSOs, satellites, VUCC grids, WAS (50 + DC), DXCC; lists, per-satellite drill-down, worked vs. LoTW-confirmed; CSV/PDF. [3]
- **LoTW station location** — DXCC → primary → secondary subdivision picker (US counties, Canadian provinces, Japanese prefectures and city/gun/ku, Russian oblasts, …) plus IOTA. [3]
- **Re-send** to LoTW/Cloudlog — editing a QSO clears its upload flags; per-QSO flags; re-send all/selected. Importing a LoTW download marks matching QSOs confirmed instead of duplicating them. [3]
- **QSO log PDF**, **voice memo → QSO stub** (built-in mic or headset). [3]
- **DXCC entity and country on every QSO**, **QRZ first name and US state fill**, **default RST by mode** (59 voice / 599 CW and data), **separate uplink/downlink modes**, UTC time in the editor, ADIF with non-ASCII names. [1, 3]

## Tracking, planning and Home

- **Automatic satellite switching** (SatPC32 Prior.SQF rules, up to 9 priorities, "take over at" elevation, finish-current-pass and pause-after-manual-pick options) with a 12 h simulated plan; wording now reflects the selected rules. [1]
- **Pass timeline** (KlaTrack style) on Home; one color per satellite across map, sky radar, globe and timelines. [1]
- **Live Activity & Dynamic Island** — next priority switch or favorite pass with countdowns [1]; adapts when other apps share the island; "Pass ended" state [1]; **self-advancing pass list, background refresh, optional scheduled next-pass activity (iOS 26+)** so it stays current while the app is closed [4].
- **Weather** (Open-Meteo) with cloud % on visible passes and transits; **activation skeds** with reminders, your own entries and an offline cache. [3]
- **AMSAT status** — new API at status.amsat.org [1]; 3–72 h window, "heard N ago", reporter grid counts, tap to select, heard marks in the Satellites list [3]; Home report card follows the selected satellite [3].
- **Space weather** trend deltas; **Nearby & DX** hub (APRS-IS, DX cluster, ADS-B from a LAN receiver, telnet). [3]
- **New Launches** — six-digit NORAD IDs, SatNOGS-first discovery, scan cache. [1]
- **Home fixes** — refresh on return from background and in-progress passes under Overhead Now with LOS (Filip Melik, PR #8); Next Passes interaction fixes (PR #5); ended passes drop off; sticky transponder menus fixed. [1]
- **Precise tuning controls** — ± with hold-to-repeat, selectable step, tap-to-type. [1]
- **Polish** — sizing fixes for narrow iPhones on the new cards and screens: compact menu pickers (CW search range, packet modem, AMSAT name, orbit types), stacked rows that used to overflow (manual HOLD/TUNE, weather, activation buttons, graphing-calculator results), smaller dense-row buttons and shrink-to-fit jog/frequency text. [4]

## Maps and tools

- **Location converter** (Maidenhead 4/6/8, DD, DMS, DDM, Plus Code, UTM, MGRS, USNG); **grid distance & bearing** (short/long path, QRZ seeding, point rotator); Grid Finder DMS, speed and course. [3]
- **Workable states and DXCC by real boundaries** with a pass picker and CSV/PDF export; globe **DX footprint** (mutual visibility); all favorites' footprints on the ground track; minimum-elevation ring; sunlit/eclipse pass curves; **star field** on the sky map. [1, 3]
- **Orbital analysis** — element-set number, epoch age, launch siblings; **debris-group screen**; **comet positions**. [3]
- **Learn / References** — orbit types (animated), Fox CubeSat anatomy, CubeSat Simulator intro and C2C reference, worldwide band plan. Graphing calculator zeros/intersections/dy-dx/Simpson integral/CSV; RL time constant. [3]
- **Notes** (in the Files app), **in-app Help**, **station readiness checklist** (first run for new installs), **reports** (favorites' TLEs, readiness, Support AMSAT sheet, contact card with QR code), **backup & restore**, **factory reset**. [3]
- **Units** — Metric / US customary / automatic. [1]

## Privacy, permissions and credits

- New network services (all user-initiated or shown only on the screens that use them): Open-Meteo (location rounded to ~1 km), APRS-IS, DX cluster, ADS-B (user's own LAN receiver), status.amsat.org. **Privacy policy and App Privacy label need review for these.**
- Microphone purpose string now covers voice memos; local-network string covers the servers, ADS-B and DX cluster. [3]
- In-app **Acknowledgments** (ft8_lib, SatelliteKit, d3-celestial BSD-3, Natural Earth, Yale BSC, Open-Meteo CC BY 4.0); README/website credit contributors. [3, 4]

---

## Website pages to update (when 1.1 is submitted)

| Page | What to add or change |
|------|----------------------|
| `index.html` | 1.1 highlights; feature grid (CW, packet, awards, servers, auto switching, Live Activity) |
| `documentation.html` | Home cards (CW, packet, tune mode, Stop all, Beacon, SSB/CW), auto switching, pass timeline, Live Activity, weather, activations, AMSAT, Nearby & DX, maps/tools, Notes, Help, readiness, backup/restore, reset |
| `catcontrol.html` | IC-705/905 Bluetooth, split VFO, satellite rigs as legs, tune modes, receive-only/beacon, engaged lock, Stop all, per-satellite CTCSS, data modes, Kenwood HF legs, rigctld VFO mode, monitor/self-test, rigctld server + network PTT safety |
| `rotator.html` | Flip fix, compass display, GS-232 az-only, SPID, manual control, read-back, self-test, Sun/Moon targets, rotctld server |
| `digitalmodes.html` | CW section exists (added in build 4) — review; packet 9600/APRS map; FT4 additions; SSTV additions; audio health |
| `logging.html` | Awards, LoTW location picker/IOTA, re-send, LoTW confirmation import, PDF, voice memos, DXCC/QRZ fill, RST by mode |
| `privacy.html` | Open-Meteo, APRS-IS, DX cluster, ADS-B, status.amsat.org; voice-memo microphone use; local-network servers |
| `source.html` | Contributors section exists (added in build 4); repository layout (widget extension, tests) |

## Still to verify on hardware before submitting

CAT: IC-705 BT re-test, FM-D/PKT data modes, IC-9700 sat-mode-off on disconnect, satellite rigs as legs, receive-only layout, Kenwood OM0/MD and TS-590 TN, rigctld VFO mode. Servers with real Gpredict/WSJT-X. Rotator SPID reply format, read-back, self-test. Packet 9600 interoperability. CW decoder on a real downlink. FT4 subtraction/deep decode/DT on air, RF-power read per rig, Tune keying. SSTV thresholds and M3/M4/S3/S4 on air. LoTW upload with subdivisions/IOTA. Live Activity while closed (self-advance, background refresh, scheduled start). App Review: keep the built-in-mic repro for background audio in the review notes.
