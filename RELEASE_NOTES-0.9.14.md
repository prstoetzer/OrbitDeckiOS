# OrbitDeck iOS/iPadOS 0.9.14 — logging, LoTW, SSTV, full-duplex FT4, rigctl

Build 1. This release remains below 1.0. It follows 0.9.13.

## Summary

0.9.14 turns OrbitDeck into an operating station, not just a tracker: an on-device
**QSO log** with **LoTW** and **Cloudlog/Wavelog** upload, **pass recording**,
**SSTV** decoding, and **full-duplex FT4** for linear transponders — all fed by a
USB audio interface or an Icom network-audio radio. It also adds a **rigctl
(Hamlib)** CAT path and fixes the satellite direction-of-travel arrow on
high-elliptical orbits.

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
  passphrase and API keys are stored in the iOS Keychain. See the privacy policy.
