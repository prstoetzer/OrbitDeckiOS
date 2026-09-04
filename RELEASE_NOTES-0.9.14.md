# OrbitDeck iOS/iPadOS 0.9.14 — logging, LoTW, SSTV, full-duplex FT4, rigctl, shared audio & CAT/rotator parity

Version **0.9.14 (16)**. This release remains below 1.0. It follows 0.9.13.

## Summary

0.9.14 turns OrbitDeck into an operating station, not just a tracker: an on-device
**QSO log** with **LoTW** and **Cloudlog/Wavelog** upload, **pass recording**,
**SSTV** decoding, and **full-duplex FT4** for linear transponders — all fed by a
USB audio interface or an Icom network-audio radio. It also adds a **rigctl
(Hamlib)** CAT path and fixes the satellite direction-of-travel arrow on
high-elliptical orbits.

## 0.9.14 (16) — SSTV Doppler decoding

- **Doppler-aware SSTV.** A fast 70&nbsp;cm bird shifts the whole audio band during a pass,
  which slanted the picture and cast its colors. The decoder now re-locks each line's sync
  pulse as a *relative* dip (it no longer gives up when Doppler pushes the sync tone up), and a
  new **Auto-tune** (on by default) reads that sync to measure and correct the frequency offset
  continuously — straight, true-colored images without touching a knob.
- **Feed-forward from rig control.** When CAT is connected, OrbitDeck feeds its live Doppler
  tuning into the SSTV decoder so the dial steps it makes mid-image don't tear the picture
  (needed for the long PD modes). With no rig connected the decoder is completely unaffected.
- **Fix an image after the pass.** From a saved image: **Fix image** straightens a leftover
  slant and tweaks brightness/contrast/saturation; **Re-decode from recording** rebuilds the
  image from the captured pass audio with new slant/Auto-tune settings, recovering the Doppler
  color cast a picture-only edit can't. Both save a new copy, non-destructively.

## 0.9.14 (12–15) — crash fix, schedule & CAT audit

- **IC-9700/9100 reverse-band satellites fixed.** Working a bird whose downlink is on the
  *other* band (e.g. AO-7 Mode B: 2&nbsp;m down / 70&nbsp;cm up) now correctly puts the downlink
  on the radio's Main VFO by exchanging Main/Sub, instead of a command the radio ignored.
- **CAT command cross-audit vs OscarWatch.** Fixed the FT-847 narrow-FM mode byte and its
  uplink-VFO read, the Kenwood TS-2000 CTCSS tone number (was off by one) and its in-satellite
  band scoping, and the IC-910 uplink-tone command.
- **Daily Schedule** no longer crashes while passes stream in, shows an "updating…" indicator,
  gained a live "Now HH:MM UTC" header you can tap to jump back to the current time, and still
  snaps to the next pass. Default elevation mask is now 0°.
- **RS-BA1 network audio** keeps the audio stream alive across FT4 restarts, and disconnecting
  now releases the radio's LAN session.

## 0.9.14 (11) — CAT & rotator parity (OscarWatch cross-audit)

- **Narrow FM on FM satellites.** FM birds (SO-50, …) are now commanded in **FM-N** — the rig
  picks its narrow FM filter (IC-910/9100/9700). Settable in CAT tuning (on by default).
- **Kenwood TS-2000 / TS-790 satellite mode.** These now enter the radio's **satellite (SATL)
  mode** with the proper Main = downlink / Sub = uplink split handshake (previously they were
  driven as a plain dual-VFO radio and never entered sat mode).
- **Two more rotators.** Added **SAEBRTrack** (serial) and **OZ9AAR URC** (TCP/JSON), joining
  GS-232, Easycomm, SPID, rotctld and PstRotator. New optional **slew lead** aims a few seconds
  ahead of the bird to cover a rotator's mechanical lag on fast passes.
- **FT4/SSTV tune-here readout.** A live **Doppler-corrected RX/TX frequency** line on the FT4
  and SSTV cards shows exactly where to set the radio, so you can operate by hand without CAT.
- **FT4 signal reports recalibrated** to read close to WSJT-X (the noise floor is now measured
  in the SSB passband instead of across the empty filter skirts, which had inflated every SNR).
- **Automatic transponder calibration (opt-in).** While you work FT4 full duplex, OrbitDeck can
  measure where your own signal lands versus your TX audio frequency and fold the difference
  into that satellite's saved calibration, refining it on every self-decode. Linear
  transponders only; enable in Settings → Audio features.
- **Doppler tracking refinements** — extra predictive lead on the receding half of a pass; a
  short, adjustable dial settle/resume so CAT doesn't fight you when you tune; and a
  band-plausibility guard on follow-dial reads.

## 0.9.14 (8–10) — shared audio, remote voice, data mode & RS-BA1 robustness

- **Shared audio hub.** Pass recording, a decoder (FT4/SSTV) and remote voice now share one
  capture, so recording can run alongside FT4/SSTV; each feature keeps its own independent
  input level.
- **Remote SSB/FM voice** over a network (RS-BA1) radio — listen through the phone and
  hold-to-talk with PTT over CAT (network audio path).
- **FT4 data sub-mode.** On a data-capable radio, starting FT4 switches it to the DATA
  sub-mode (USB-D/LSB-D via `06`+`1A 06` on the IC-9700, DIG on the Yaesu FT-8x7, Hamlib PKT
  via rigctld) and restores plain SSB on stop. Default on; settable.
- **IC-9700 satellite layout fix** — MAIN = downlink (RX), SUB = uplink (TX), so RS-44 no
  longer comes out with the sidebands swapped; MAIN/SUB bands are assigned automatically.
- **RS-BA1 network robustness** — a receive watchdog catches a silently dead link, the
  keepalive cadence matches wfview, network audio re-establishes after a reconnect, and a
  transient Wi-Fi path blip is ridden through instead of forcing a full re-login.

## 0.9.14 (7) — running station robustness

- **Everything keeps running off the home screen and in the background.** CAT, the rotator,
  pass recording, SSTV and FT4 keep running as you move around the app, and the audio modes
  keep decoding/recording with the screen locked or the app backgrounded during a pass
  (`UIBackgroundModes: audio`).
- **Connections re-establish when you return.** If a link drops while the app is
  backgrounded/suspended (iOS reclaims BLE + UDP sockets), CAT and the rotator reconnect on
  foreground; audio decoders rebuild their capture graph after a phone-call/Siri
  interruption.
- **Icom network (RS-BA1) disconnect fixed.** A dropped control/serial socket after connect
  used to be logged but never acted on — the app kept firing tune commands into dead sockets
  and never freed the radio's session, so PTT went dead and the radio reported "a session is
  already open" on reconnect. The transport now tears down cleanly (frees the session) and
  the controller auto-reconnects (3 tries, 2&nbsp;s backoff). PTT is logged for diagnosis.
- **Rotator auto-reconnect** — the rotator now reconnects after an unexpected link drop, like
  CAT.
- **Audio setup is saved** — input/output gain for recording, SSTV and FT4 persists across
  launches; the SSTV input-level control is always available in Setup.

## 0.9.14 (6) — refinements

- **FT4 audio Doppler compensation is now on by default — and correct on inverting
  transponders.** Because the CAT dial is held steady across each slot, the within-slot
  drift *must* be removed in the audio domain, so RX de-chirp and TX pre-chirp are now
  default-on. The transmit correction is now **sideband-aware**: on an inverting linear
  transponder the uplink is LSB, so the correction sign flips — the previous single-sign
  correction doubled the drift on inverting birds (others reported smearing; you couldn't
  decode your own signal). See the [Doppler deep dive](https://orbitdeckios.n8hm.radio/digitalmodes.html#doppler).
- **FT4 transmits start on time.** A pre-arm steps the dial and keys PTT in the dead air
  before your slot, so the burst starts at the slot boundary instead of up to ~0.8&nbsp;s
  late (a bad `dT` that hurt others' decodes). A diagnostic logs each transmission's `dT`.
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
