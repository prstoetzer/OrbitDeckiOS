# TestFlight — OrbitDeck 0.9.18 (8) · What to Test

This build fixes an IC-9700 satellite-mode bug, hardens the Icom network link, fixes a
pass-recording failure, adds a data-mode option for FT4, and prevents audio-feature
conflicts. Icom users (9700/705) and anyone recording passes, please exercise these.

## Headline changes
- **IC-9700 modes fixed.** On the 9100/9700 the satellite layout is Main=RX/Sub=TX; we were
  putting the modes on the swapped VFOs, so an inverting bird (e.g. RS-44) came out downlink
  LSB / uplink USB. Now correct (downlink USB / uplink LSB on RS-44).
- **Icom network (RS-BA1) auto-recovers a dead link.** A new watchdog detects a silently
  dropped connection (Wi-Fi blip / radio off) and reconnects — plus a corrected TX-audio
  packet length.
- **Pass recording no longer fails to create the file** ("…couldn't be completed …560226676"),
  which could happen on a cold launch.
- **Data mode for FT4** (new setting, default on).
- **One audio feature at a time** with a clear message (shared-capture coexistence is planned).

## What to test

### 1. IC-9700 / IC-9100 modes (RS-44 and other inverting birds)
- Connect the 9700, select RS-44 (or another inverting linear bird), start Doppler tracking.
- **Good:** downlink shows **USB**, uplink shows **LSB**, on the correct bands (downlink on
  MAIN/RX, uplink on SUB/TX). Report the satellite and what you see.
- Check a non-inverting bird too (modes should be sensible, unchanged).

### 2. IC-9700 / IC-705 network robustness
- Connect over Wi-Fi (RS-BA1). Mid-session, drop Wi-Fi briefly or power-cycle the radio.
  **Good:** status shows reconnecting and it comes back within a few seconds; the radio does
  not complain about an existing session.
- Confirm PTT still keys for FT4 after a reconnect.

### 3. Pass recording (the file-creation fix)
- **Cold start:** launch the app fresh and start a pass recording as the *first* audio action
  (no FT4/SSTV first). **Good:** it records and the clip appears on the Log screen — no
  "could not create the recording file" error.
- Record again after using FT4/SSTV; still fine.

### 4. Data mode for FT4 (new — Settings → Audio features → "Use data mode for FT4", default on)
- On a data-capable radio, start FT4 and confirm the rig switches to the data sub-mode, then
  back to plain SSB when you stop FT4:
  - **CI-V** (IC-9700/9100/705/905/7100/7000): USB-D / LSB-D.
  - **rigctld (Hamlib)**: PKTUSB / PKTLSB — works on any Hamlib-supported radio with a data mode.
  - **Yaesu FT-817/818/857/897**: DIG (set the radio's DIG MODE menu to USB).
- Turn the setting **off** and confirm FT4 leaves the rig on plain USB/LSB (for operators
  feeding audio via mic/headphone).

### 5. Audio-feature exclusivity
- Start FT4 (or SSTV, or recording), then try to start another. **Good:** the second shows
  "Audio is in use by … Stop it first." and doesn't start. Stop the first, then the other
  starts normally.

## Please report
- IC-9700/9100 modes still swapped on any bird (name it).
- Network connection that won't reconnect, or PTT dead after reconnect.
- Recording still failing to create a file (include the error).
- FT4 not switching to/from data mode on a supported radio (name the radio + connection type).

## Diagnostics
Log categories: `cat` (connect/drop/reconnect, `setPTT`, watchdog), `audio`
(`usb-audio: restarting capture …`), `ft4` (`FT4 TX dT=…`).

## Not in this build
Pass recording coexisting with FT4/SSTV, and a live-listen monitor, are planned via a shared
audio-capture hub (see `SCOPE_AUDIO_HUB.md`) — for now only one audio feature runs at a time.
Half-duplex single-radio FT4 is still planned (`SCOPE_HALFDUPLEX_FT4.md`).
