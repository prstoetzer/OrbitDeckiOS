# OrbitDeck iOS/iPadOS 0.9.14 (6) — logging, LoTW, SSTV, full-duplex FT4, rigctl

Version **0.9.14 (6)**. This release remains below 1.0. It follows 0.9.13.

## Summary

0.9.14 turns OrbitDeck into an operating station, not just a tracker: an on-device
**QSO log** with **LoTW** and **Cloudlog/Wavelog** upload, **pass recording**,
**SSTV** decoding, and **full-duplex FT4** for linear transponders — all fed by a
USB audio interface or an Icom network-audio radio. It also adds a **rigctl
(Hamlib)** CAT path and fixes the satellite direction-of-travel arrow on
high-elliptical orbits.

## 0.9.14 (6) — refinements

- **CAT cross-audited against OscarWatch-Tracker + Hamlib.** FT-847 now enters satellite
  mode at connect (0x4E) so its SAT RX/TX VFO tracking drives real receive/transmit;
  the FT-736R gets true full-duplex via its split VFO (freq 0x2E / mode 0x27, full-duplex
  0x0E — from Hamlib ft736.c). Receive-only radios can no longer be assigned the uplink.
- **Doppler tuning is smarter near closest approach.** The predictive lead now tapers to
  ~zero at TCA (where a fixed forward lead over-shoots), and the dial deadband tightens
  when the Doppler is slewing fast so the frequency updates more often exactly when it
  matters — while relaxing again on the slow legs to spare the CI-V/BLE bus.

## 0.9.14 (5) — refinements

- **IC-9700 network CAT fixes** — the 9700 (and IC-9100) now automatically enter
  **satellite mode** and get their **MAIN/SUB band assignment** (`07 D2`) on connect,
  which they require for full-duplex Doppler tuning to take effect. (The IC-821 path is
  unchanged.) CAT diagnostics now log *why* the loop can't tune (no satellite /
  transponder / Track Doppler off) and confirm the tuning commands being sent.
- **FT4 holds the dial steady across each slot** — with a connected CAT radio, Doppler
  updates are stepped only at slot boundaries (never mid-slot), so a coherent decode is
  never smeared; the RX audio correction removes the residual within-slot drift.
- **AOS/LOS readouts** on the recording/SSTV/FT4 cards now stay current mid-pass and when
  switching satellites (kept through transient prediction hiccups instead of blanking).
- **Favorite the active satellite** from the header star on Home and the feature screens.

## 0.9.14 (4) — refinements

- **PSKReporter (opt-in)** — upload the FT4 stations you decode to PSKReporter's
  public map. Off by default; enable in **Settings → PSKReporter**. Reports the
  absolute downlink RF (Doppler-corrected downlink dial from CAT, or the transponder
  downlink center) plus the decode's audio offset. Disclosed in the privacy policy.
- **FT4 audio Doppler correction (experimental)** — optional, off by default:
  **RX** de-chirps each received slot before decoding (the downlink drift is common
  to all signals on a linear transponder); **TX** pre-compensates your burst. Both
  need a configured transponder and on-air validation.
- **Icom network (RS-BA1) connect diagnostics** — the handshake now reports *where*
  it stalled (unreachable / login rejected / connection refused), with specific
  IC-9700 guidance (wired-Ethernet subnet, Network Control + CI-V Transceive, single
  network session). Verified our RS-BA1 byte layout against wfview/kappanhang.
- **Diagnostic logs** — a Settings → Diagnostics screen records rig/audio/network
  activity to a file you can share with the developer when troubleshooting.
- **Keychain** — a "Clear all saved passwords & keys" action; every credential uses a
  distinct Keychain key (Keychain items persist across app deletion).
- **Offline robustness** — element/transmitter/space-weather auto-refreshes fail
  quietly to a status line instead of popping an alert when you're offline.
- **Satellites** — favorite a satellite directly from the active (above-horizon) list.
- **Rig/rotator setup** — Radio picker now sits above Connection type; port is a
  numeric keyboard field; switching connection type fills the standard port
  (Icom 50001 / rigctld 4532).

## Logging & uploads

- On-device satellite **QSO log** with a Home **Log QSO** quick-entry card
  (prefilled from the selected satellite, transponder and your grid) and a
  dedicated **Log** screen (add/edit, ADIF import/export, upload menu).
- **LoTW**: import your callsign certificate as a **.p12**; OrbitDeck signs the
  `.tq8` on device (RSA-PKCS1v15 over SHA-1, LoTW V2.0 sigspec) and uploads the
  whole log in one pass — no computer needed. Certificate stays on device;
  passphrase in the Keychain.
- **Cloudlog / Wavelog** upload (URL + station profile + API key).
- Automatic **LoTW satellite-name normalization** (e.g. `FOX-1B (AO-91)` → `AO-91`).
- Full CardSat field parity, including rover multi-grid (VUCC).

## Digital modes & audio

- **Pass recording** — record the received audio to a WAV tagged with the
  satellite and time; clips list on the Log screen.
- **SSTV** — live decode of Robot 36/72, Scottie S1/S2/DX, Martin M1/M2, Wraase
  SC2-180 and PD modes, with a dedicated **SSTV Images** screen and export to
  Photos.
- **Full-duplex FT4** for linear transponders — decode the downlink while
  transmitting the uplink on alternating 7.5 s slots, using the MIT-licensed
  ft8_lib. Log FT4 QSOs with one tap.
- **PTT** for FT4 over CAT (CI-V, Yaesu, Kenwood, rigctld, Icom network) where
  available; otherwise VOX/manual with a prominent on-screen **TRANSMIT NOW**
  indicator.
- **FT4 is ~100% duty cycle** — a persistent banner reminds you to limit power out
  of respect for others sharing the transponder.
- The recording / SSTV / FT4 cards appear only when a USB audio interface is
  connected or an Icom network-audio radio is configured; the Log card appears
  only when logging is enabled.

## rigctl (Hamlib)

- New **rigctld** CAT connection type: drive any Hamlib-supported radio over the
  network (Hamlib NET rigctl, default port 4532), including full-duplex split.

## Fixes

- **HEO direction-of-travel arrow** — the satellite motion arrow (Home polar plot,
  Ground Track, and 3D globe) now points correctly on high-elliptical orbits and
  near the zenith, using a period-adaptive, azimuth-wrap-safe bearing instead of a
  fixed short time step.

## Under the hood

- New subsystems: `Log/`, `Audio/`, `Recording/`, `DigitalModes/` (SSTV + FT4),
  and a `rigctld` transport in `CAT/`. Vendored the MIT **ft8_lib**
  (see `THIRD_PARTY_NOTICES.md`). Gzip for LoTW is pure Swift (no libz).

## Testing notes

- FT4, SSTV timing, the **Icom network-audio path (experimental)**, rigctld, and
  the BLE serial rotators are implemented to spec but are best validated on real
  hardware/on-air; each is flagged in source. Pass recording over USB audio and
  the LoTW/ADIF paths are the most straightforward to try.

## Privacy

- Audio is captured only while recording/decoding and stays on device; SSTV images
  export to Photos only when you choose. The QSO log stays on device; uploads go
  only to LoTW or your Cloudlog instance when you tap upload. Certificate
  passphrase and API keys are stored in the iOS Keychain. PSKReporter uploads are
  off unless you opt in. Diagnostic logs stay on device unless you share them. See
  the privacy policy.
