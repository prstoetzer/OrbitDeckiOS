# OrbitDeck 1.1 — change log since 1.0 (working notes)

Running log of everything added or changed since **1.0 (18)**, the App Store release, for the 1.1 App Store notes and the website/documentation update. **The website (`docs/`) has been updated for 1.1** (build 5); see "Website" at the end.

Builds so far: 1.1 (1) → 1.1 (5). Everything below is in `main`; the build each item landed in is shown in brackets. Build 5's changes are collected in "Build 5 additions" below (and tagged [5] where they change an earlier item).

---

## Highlights (for the App Store "What's New")

- **CW decoder with DeepCW** — copy Morse on the downlink with DeepCW, an on-device neural decoder that copies weak signals and uneven fists, or the Classic decoder with tone tracking, adaptive speed and prosigns; tap a callsign to log it. [4, DeepCW 5]
- **Packet / APRS** — built-in 1200 and 9600 baud modems, APRS messaging and beacons through satellites and the ISS, a map of heard stations, or a Bluetooth LE KISS TNC. [1–3]
- **Awards and a better log** — VUCC grids, WAS, DXCC and per-satellite totals; LoTW location picker for every entity LoTW supports; voice memos that become QSO entries; PDF log reports. [3]
- **Two-radio stations with satellite rigs**, a live tune-mode selector, Stop all, and rigctld/rotctld servers so desktop programs can share OrbitDeck's radio and rotator links. [3]
- **Automatic satellite switching** (SatPC32 style) with a KlaTrack-style pass timeline. [1]
- **Rotator**: manual control, position read-back, self-test, Sun/Moon aiming. [3]
- **Live Activity & Dynamic Island** for the next pass, now staying current while the app is closed. [1–4]
- **Planning extras**: weather and cloud cover on visible passes, activation reminders, backup & restore, in-app Help and a station readiness checklist. [3]
- **Safer transmitting** — one feature keys the radio at a time, every key has a time limit, Stop all and disconnects always unkey, and network clients need your approval before they can control the radio or rotator. [5]
- **More dependable data** — the log is never overwritten if a file can't be read, Cloudlog uploads are checked, and imported orbital elements are kept. [5]

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
- **Stop all** — releases PTT, stops FT4/packet, disconnects CAT, parks the rotator. [3] Also stops remote-voice transmit and ends rigctld/rotctld client control. [5]
- **Passband-edge banner**, **CAT monitor** (per-frame trace) and **guided self-test**, **CAT rate floor** for slow serial rates, **tilt-to-tune** (optional). [3]
- **No-CAT HOLD/TUNE calculator** — hold one leg at a fixed dial (HT, FT-817) and read the other's corrected dial live.[3]; type the held dial in MHz, kHz or Hz with a live result and a keypad Done button [4]
- **Kenwood TS-590/590SG/890/990** as single-radio legs. [1]
- **rigctld** — VFO mode with `\chk_vfo` probe (avoids Hamlib retuning the wrong VFO on Icom sat rigs); split method kept as a fallback and for existing setups. [3]
- **Clean disconnect** — CTCSS off, Icom satellite mode off, back to MAIN/VFO A. [1]
- **Safety** — PTT refuses to key on a transponder with no uplink; two-radio BLE setup mistakes are caught before connecting (same adapter for both radios, missing device, Radio 2 not set up). [1, 3]
- Many CAT fixes from the OscarWatch cross-check (IC-9700 band exchange, FT-847 same-band hold, TS-2000 data mode, TH-D74/D75 stepping, FM-N filter bytes …). [1]

## Network servers

- **rigctld server** (TCP 4532) and **rotctld server** (TCP 4533) so Gpredict, SatPC32, WSJT-X or a logger on your LAN can read/drive the radio and rotator through OrbitDeck's link. Off by default. Network PTT is a separate opt-in (default off) with a 3-minute keyed limit and automatic unkey when the client drops. Foreground (or background-audio) only. [3] New clients from other devices need approval (Allow once / Always allow / Deny), and network PTT is limited to the client's own key. [5]

## Rotator

- **Flip mode fixed** — decided once per real pass; no more flipping back mid-pass. [1]
- **Compass display** in ±180° mode; **GS-232 azimuth-only** controllers; **SPID** reply checks with retries. [1]
- **Manual control** — jog, go-to az/el, Stop, Park, resume tracking. [3]
- **Position read-back** with stall warning; **self-test**; **monitor**. [3]
- **Sun / Moon / fixed-bearing targets** (sun-noise G/T checks, EME); "point rotator" from the Grid distance tool. [3]

## Digital modes and audio

- **CW decoder** — automatic tone search (300–1,200 Hz) with AFC, 50/100/200 Hz filters, squelch, adaptive 5–50 WPM (or fixed) with Farnsworth handling, full ITU table + prosigns; spectrum strip (tap to tune), transcript with copy/share/timestamps, tappable callsigns → quick log. Runs alongside recording, FT4 and SSTV. [4] This is now the **Classic** decoder; DeepCW became the default in build 5 (see below). [5]
- **Packet / APRS** — built-in AFSK 1200 modem and BLE KISS TNC (B.B. Link for the TH-D74/D75) [1]; UISS-style messages, per-satellite path/format, macros, PTT watchdog, timed beacon, heard-station list, automatic QSO logging when a two-way exchange completes [1]; **9600 baud G3RUH** modem, **APRS map** of heard stations with symbols, data mode [1].
  - **Pass log** — every frame heard or sent is saved per pass (last 30 kept) with a session list, per-pass statistics (frames and stations heard, sent/digipeated and success %, median digipeat delay, frames per minute) and TNC2/UISS-style text and CSV export. [4]
  - **Monitor** — full via path with `*` on the digipeater that repeated it and satellite digipeaters (RS0ISS, ARISS, PSAT…) highlighted; raw TNC2 view; filters by callsign, text, digipeated only, and hide beacons/telemetry/status. [4]
  - **Alerts** — haptic and sound (or a notification in the background) for messages to you, a watch list of callsigns/words, and your frame being digipeated; optional spoken readout of messages and bulletins. Sounds and speech are skipped whenever the phone's audio output feeds the radio, and never play during transmit. [4]
  - **Minimum elevation** for sending and beacons (global, per-satellite override); **beacon when the satellite is first heard**; **status/text beacon** alone or alternating with the position; **automatic resend** of unacknowledged messages (2×, 30 s apart, with retry state). [4]
  - **APRS objects, items (incl. killed), weather** (positionless and in positions) and **third-party** packets decoded; objects/items on the station map, weather in the station list. [4]
  - **KISS over TCP** — Direwolf, UZ7HO soundmodem or a LAN TNC (default port 8001), with automatic reconnect. [4]
  - **Satgate (RF → APRS-IS)** — opt-in, receive-only: gates heard packets with `qAR,<your call>`, 30 s duplicate suppression, never own/NOGATE/RFONLY/TCPIP packets, never Internet → RF; passcode in the Keychain. **Privacy policy updated [5]; App Privacy label still to review:** with the satgate on, heard packets and the operator's callsign/passcode go to the chosen APRS-IS server. [4]
- **FT4** — late start within 2 s of a slot, wait-and-pounce, CQ block list, remembered `<…>` callsigns, per-transponder echo calibration, missing-grid warning, more robust message parsing; Doppler hold only on the FT4 transponder. [1]
- **FT4 decoding** — signal subtraction with a second/third decode pass for weaker stations under strong ones (on by default); **Decode again (deep)** on the previous slot (button or long-press the waterfall: more candidates, 50 LDPC iterations, de-chirp grid for sliding uplinks), merged and tagged "deep"; DT column (WSJT-X convention) with an optional |DT| > 1.5 s filter. [4]
- **FT4 Band Activity** — shading for calls and VUCC grids not yet in the log, a "Target" tag for pounce targets, and an All / Me & my echoes filter. [4]
- **FT4 waterfall** — faster noise-floor tracking, 2–4 averaged FFT frames per line, slot lines with UTC labels, 12/24/48 s history. [4]
- **FT4 safety** — TX watchdog (default 6 min, 2–15) halts TX when nothing addressed to you is decoded; refuses to start on FM-only transponders (linear birds incl. AO-7 unaffected); courtesy warning when CAT reads RF power above ~30 W (CI-V, Kenwood, rigctld); **Tune** button (≤ 10 s carrier at the TX audio frequency). Sequencer fixes: a repeated RR73 after completion gets one more 73 without a duplicate log; a stray 73/RR73 from an unworked station no longer starts or logs a QSO. [4]
- **SSTV** — per-satellite expected modes and damaged-VIS fallback, Robot 36/72 guard, noisy-line repair, chroma smoothing, combined repeat copies, partial captures placed correctly, auto start/stop by elevation. [1]
- **SSTV Martin M3/M4 and Scottie S3/S4** (128-line variants), decoded from VIS. [4]
- **Screen stays awake automatically** while FT4, SSTV, packet, the CW decoder or a pass recording runs, on any screen; released when the last one stops (the Home opt-in is unchanged). [4]
- **Safety review fixes** — FT4: Tune or a burst stopped while PTT-on is still in flight now unkeys again; Tune clears a pre-armed slot; the FM-only check runs before every burst, so switching to an FM transponder mid-session stops TX; the RF-power read no longer makes FT4 skip its per-slot Doppler step. Packet: message retries are dropped when the satellite changes (the old path is in the frame) and need a known elevation; speech and alert sounds never play while a USB audio interface is connected, even on KISS; fixed a crash on the "digipeated" alert with an empty via path. Screen-awake tracking no longer re-renders the whole app on every meter update. [4]
- **Performance** — FT4 and the other digital modes use far less main-thread time: the FT4 activity log is saved in the background (batched every few seconds) instead of re-encoding the whole log on the main thread several times per slot; the waterfall's spectrum, averaging and image are vectorized with no per-line allocations; the TX meter no longer runs its own main-thread loop (it also shows during Tune); decodes land as one update per batch; callsign-hash lookups are rebuilt lazily; the packet meter no longer waits on the demodulator; and the CAT Doppler loop stops re-publishing unchanged state every tick, which re-rendered Home. Level meters and waterfalls (FT4, CW, packet, SSTV, recording) now redraw only themselves instead of their whole card ten times a second, the Band Activity rows re-render only when decodes change, and the FT4 waterfall defaults to 12 s of history (10 lines a second, smoother scrolling). [4]
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
- **Live Activity & Dynamic Island** — next priority switch or favorite pass with countdowns [1]; adapts when other apps share the island; "Pass ended" state [1]; **self-advancing pass list, background refresh, optional scheduled next-pass activity (iOS 26+)** so it stays current while the app is closed [4]. Reworked for consistency [4]: refreshes are serialized so only one activity ever runs (no duplicate starts, no end-then-restart at launch before the catalog loads); dead activities iOS ended at its 8-hour limit are cleared from the Lock Screen, and one older than 4 h is renewed when the app is opened outside a pass; replanning no longer jitters switch times ("14:04Z" ↔ "14:05Z") or pushes needless updates; a started scheduled activity no longer keeps top relevance forever. The widget now runs through a whole pass without a redraw (AOS countdown, then an "Up for" timer (the pass length, counting down to LOS once the pass starts) and a progress bar, all date-driven) and spends its one stale-date redraw at LOS to move on to the next pass; adds AOS/LOS directions, "Then …" for the following pass, and for favorites keeps the pass being worked instead of jumping to one rising later. Uses the selected satellite when there are no favorites; the scheduled activity now targets the pass after the two the running one can reach by itself. Starts, ends, replacements and failures are logged (Debug log, category "liveactivity").
- **Live Activity on Apple Watch** — a compact Smart Stack layout (name, live countdown, pass progress, max elevation). The Live Activity extension now requires iOS 18; on iOS 17 the app runs without it. [4]
- **Weather** (Open-Meteo) with cloud % on visible passes and transits; **activation skeds** with reminders, your own entries and an offline cache. [3]
- **AMSAT status** — new API at status.amsat.org [1]; 3–72 h window, "heard N ago", reporter grid counts, tap to select, heard marks in the Satellites list [3]; Home report card follows the selected satellite [3].
- **Space weather** trend deltas; **Nearby & DX** hub (APRS-IS, DX cluster, ADS-B from a LAN receiver, telnet). [3]
- **New Launches** — six-digit NORAD IDs, SatNOGS-first discovery, scan cache. [1]
- **Home fixes** — refresh on return from background and in-progress passes under Overhead Now with LOS (Filip Melik, PR #8); Next Passes interaction fixes (PR #5); ended passes drop off; sticky transponder menus fixed. [1]
- **Precise tuning controls** — ± with hold-to-repeat, selectable step, tap-to-type. [1]
- **Polish** — sizing fixes for narrow iPhones on the new cards and screens: compact menu pickers (CW search range, packet modem, AMSAT name, orbit types), stacked rows that used to overflow (manual HOLD/TUNE, weather, activation buttons, graphing-calculator results), smaller dense-row buttons and shrink-to-fit jog/frequency text. [4]
- **Home card fit** — the Setup sections of the FT4, SSTV, CW and packet cards no longer push their switches past the card edge (a custom disclosure replaces the system one, which inset its content); Home cards are now inset from the screen edges, so switches, menus and buttons no longer sit under the scroll indicator; the FT4 Transmit/Auto-seq/Tune row wraps instead of running off the card; the packet Connection choice is a menu; CW status and SSTV calibration labels shrink to fit larger text sizes. [4]

## Maps and tools

- **Location converter** (Maidenhead 4/6/8, DD, DMS, DDM, Plus Code, UTM, MGRS, USNG); **grid distance & bearing** (short/long path, QRZ seeding, point rotator); Grid Finder DMS, speed and course. [3]
- **Workable states and DXCC by real boundaries** with a pass picker and CSV/PDF export; globe **DX footprint** (mutual visibility); all favorites' footprints on the ground track; minimum-elevation ring; sunlit/eclipse pass curves; **star field** on the sky map. [1, 3]
- **Orbital analysis** — element-set number, epoch age, launch siblings; **debris-group screen**; **comet positions**. [3]
- **Learn / References** — orbit types (animated), Fox CubeSat anatomy, CubeSat Simulator intro and C2C reference, worldwide band plan. Graphing calculator zeros/intersections/dy-dx/Simpson integral/CSV; RL time constant. [3]
- **Notes** (in the Files app), **in-app Help**, **station readiness checklist** (first run for new installs), **reports** (favorites' TLEs, readiness, Support AMSAT sheet, contact card with QR code), **backup & restore**, **factory reset**. [3]
- **Units** — Metric / US customary / automatic. [1]

## Privacy, permissions and credits

- New network services (all user-initiated or shown only on the screens that use them): Open-Meteo (location rounded to ~1 km), APRS-IS, DX cluster, ADS-B (user's own LAN receiver), status.amsat.org. **Privacy policy updated for these [5]; App Privacy label still to review.**
- Microphone purpose string now covers voice memos; local-network string covers the servers, ADS-B and DX cluster. [3]
- In-app **Acknowledgments** (ft8_lib, SatelliteKit, d3-celestial BSD-3, Natural Earth, Yale BSC, Open-Meteo CC BY 4.0); README/website credit contributors. [3, 4]

---

## Build 5 additions

### CW: DeepCW neural decoder [5]

- **DeepCW** (by e04, MIT; converted to Core ML and bundled) is now the default CW decoder. It copies the 400–1200 Hz band, including weak signals and uneven fists; text appears in bursts about 2 s behind the audio. Runs on the device (about 6 ms per window on CPU+GPU).
- **Classic** stays as an option (CW Setup → Decoder: DeepCW / Classic) for pitches outside 400–1200 Hz, prosigns, and following one signal among several. Squelch, bandwidth and speed settings show only for Classic; the pitch, speed, SNR and spectrum readouts work with both. Falls back to Classic if the model is missing.
- Credited in Acknowledgments and THIRD_PARTY_NOTICES.md; conversion tooling, a Python reference decoder and a test-audio generator in `tools/deepcw/`.

### Transmit safety [5]

- **One PTT authority** — one feature holds the transmitter at a time (FT4, FT4 Tune, packet, remote voice, a rigctld client); others are refused ("Transmitter in use by …"). Keys and unkeys go out strictly in order, so an unkey is never overtaken; releasing a pending key cancels it. Each feature has a maximum key time, with a 4-minute absolute cap.
- PTT is released on Stop all, disconnect, link drop, and when OrbitDeck goes to the background for remote voice, Tune and network clients (FT4 and packet sessions keep running). Disconnect and link drop send PTT-off first; an unconfirmed unkey is retried on reconnect and a warning is shown; quitting the app sends PTT-off.
- **FT4** — Stop always releases PTT (including a key still in flight); Tune needs Transmit on and a callsign; sends without a callsign are refused.
- **Packet** — Stop cancels a pending transmission; a refused key no longer plays the frame; playback errors unkey at once. Monitoring starts without a callsign; every transmit path checks for one.
- **Remote voice** — keys only after playback starts; 3-minute limit; unkeys on background, gesture cancel or leaving the screen.

### Network server approval [5]

- rigctld/rotctld servers hold new clients from other devices until you choose **Allow once**, **Always allow** or **Deny** (prompt on any screen, or in the server settings); unanswered requests are denied after 30 s or when OrbitDeck goes to the background. Clients on the same device are always allowed; "Require approval for new clients" is on by default; allowlist entries can be swiped away.
- VPN and cellular interfaces are refused. `T 0` only releases the caller's own key, and a forced release can't leave a stale client key.

### Rotator [5]

- Failed position commands are retried with a 2–10 s backoff instead of being skipped until the target moved far enough.

### Logbook integrity [5]

- Save errors are shown in a banner. An unreadable log file is moved to `<name>.corrupt-<timestamp>.json` before starting empty, and never overwritten (QSO log, recordings, SSTV and FT4 files).
- An upload only marks QSOs that still match what was sent; QRZ fills clear the Cloudlog mark like any edit.
- Cloudlog/Wavelog replies are checked: success needs a created status and every QSO imported, otherwise nothing is marked and the server's messages are shown.
- Cloudlog URLs must be https, except plain http to a local-network host (with an unencrypted-key warning); ATS errors explain the fix.
- ADIF field lengths and frequencies can't overflow.

### Catalog and prediction [5]

- CelesTrak cooldown is per group/URL (plus a device-wide back-off after rate limiting), so switching groups fetches the new one.
- Imported TLE/OMM element sets are kept across launches and catalog updates; newer imports win until the feed catches up; listed under Satellites → Add → Imported Elements with swipe-to-delete.
- Malformed element values (NaN, infinity, out of range) are skipped and counted instead of crashing.
- **BSTAR fix** — TLE parsing reads BSTAR (and Kozai mean motion) from the text itself; SatelliteKit's parser left drag at about 1e-53, so decay was effectively ignored.
- Always-visible (GEO) satellites such as QO-100 show a continuously visible state; Home no longer hangs on them.
- TLE export skips NORAD IDs that can't be written (instead of writing another satellite's ID); manual entry warns above 339999.
- Location follow starts as soon as permission is granted on first run.

### Live Activity redesign [5]

- **Truthful layouts** — every layout (Lock Screen, Dynamic Island expanded/compact/minimal, Smart Stack) reads correctly through AOS and LOS without a redraw: countdowns sit next to the clock time they count to, compact shows the AOS/LOS time, minimal is an AOS-to-LOS ring; a background wake at AOS.
- **Stale state** — content iOS marks out of date is dimmed with "Open OrbitDeck to update"; Settings explains when Background App Refresh is off.
- **Deep link** — tapping the activity opens OrbitDeck on that satellite.
- **VoiceOver** labels for every layout.
- **No truncation** — timers are sized for their widest reading (hours-away countdowns no longer cut off), the Smart Stack gives the timer its own line, times and long names fall back to shorter forms.
- Element epochs are part of the replan check; a scheduled activity starts no earlier than the running pass's LOS.

### UI review fixes (summary) [5]

- Simulator UI review: no mid-word wraps or truncation on Next Passes, Satellites, Pass Detail, Illumination, Orbital Analysis, Sky Radar, Home, Radio and Track; menu close button, current-screen highlight and VoiceOver buttons; labeled fields throughout Settings, Log, DX Cluster and activations; empty states for Mutual Windows, satellite-picker favorites, search and Daily Schedule.
- Functional fixes: band names ("30 m") no longer converted to feet; friendlier location errors; APRS-IS port without a thousands separator; moon phase names; AO-7 phase uncertainty; consistent meteor-scatter verdict; correct downlink on the exported pass card; rotator enable toggle; Awards opens as a sheet from Log.
- Audio-feature cards name their real input (USB, network radio or built-in mic); FT4 card polish (plain headline, dB gain sliders, visible meter track); units keep their case in section headers; network-client approval prompts appear on any screen.
- Cleanups: the unused "Assign MAIN/SUB bands (IC-9100/9700)" toggle is gone (the IC-9100/9700 MAIN/SUB exchange is automatic); "Clear all saved passwords & keys" also deletes the imported LoTW certificate; Tiny BASIC FOR/NEXT without line numbers loops on one line instead of crashing; the BASIC files caption shows the real folder (Application Support/OrbitDeck/Basic).

### Website [5]

- `docs/` rewritten for 1.1: home page, documentation, rig control, rotator, digital modes (DeepCW and Classic CW), FT4 on the IC-9700 over the network, logging, privacy and source pages, with refreshed screenshots and Live Activity / Dynamic Island images. Requirements: iOS 17; Live Activity iOS 18; scheduled next pass iOS 26.

---

## Website

The website (`docs/`) has been updated for 1.1 (build 5): every page listed in the earlier plan (`index`, `documentation`, `catcontrol`, `rotator`, `digitalmodes`, `ft4-ic9700-network`, `logging`, `privacy`, `source`) now covers the 1.1 features above, including DeepCW, transmit safety, server approval, logbook integrity and the Live Activity redesign. `PrivacyInfo.xcprivacy` now declares Precise and Coarse Location, User ID (callsign) and Other User Content, all linked and for App Functionality, with no tracking; the App Store **App Privacy** label must match (answers in `AppStore-1.1/app-privacy.md`).

## Still to verify on hardware before submitting

CAT: IC-705 BT re-test, FM-D/PKT data modes, IC-9700 sat-mode-off on disconnect, satellite rigs as legs, receive-only layout, Kenwood OM0/MD and TS-590 TN, rigctld VFO mode. Servers with real Gpredict/WSJT-X, including client approval (Allow once / Always allow / Deny, the 30 s timeout, denial in the background) and network PTT. Rotator SPID reply format, read-back, self-test. Packet 9600 interoperability. CW decoder on a real downlink: DeepCW (weak and drifting signals, the ~2 s delay) and Classic. PTT authority on real radios: FT4, Tune, packet, remote voice and network-client keys hand over cleanly, Stop all / disconnect / link drop always unkey, and the unconfirmed-unkey warning and retry. FT4 subtraction/deep decode/DT on air, RF-power read per rig, Tune keying. SSTV thresholds and M3/M4/S3/S4 on air. LoTW upload with subdivisions/IOTA. Live Activity while closed: runs through a pass and moves on at LOS with the app suspended, background refresh, scheduled start (iOS 26), single activity after reopening/relaunch, renewal after 4 h, the redesigned layouts on device (Lock Screen, Dynamic Island expanded/compact/minimal, Smart Stack on Apple Watch) on small/large phones, at large text sizes and with another app sharing the island, stale dimming, tap-to-open and VoiceOver. App Review: keep the built-in-mic repro for background audio in the review notes.
