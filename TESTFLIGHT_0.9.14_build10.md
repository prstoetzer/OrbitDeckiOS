# TestFlight — OrbitDeck 0.9.14 (10) · What to Test

Fixes from build-9 feedback: FT4 data mode on the IC-9700 (now uses the correct CI-V
command), and independent audio levels when pass recording runs alongside FT4/SSTV.

## Headline changes
- **IC-9700 FT4 data mode fixed.** FT4 now switches the radio into the **data sub-mode
  (USB-D/LSB-D)** using the IC-9700's satellite-mode data sequence (`06` mode + `1A 06`),
  verified against the IC-9700 CI-V Reference Guide and OscarWatch.
- **Per-feature audio levels.** Pass recording and a decoder no longer share one gain, so
  running them together no longer makes the level/waterfall look wrong.

## What to test

### 1. IC-9700 data mode on FT4 (the main fix)
- Connect the IC-9700 over the network, select RS-44 (or another linear bird), and start
  **FT4** with **Use data mode for FT4** on (Settings → Audio features, default on).
- **Good:** the radio shows **USB-D on the downlink and LSB-D on the uplink** (the "-D" data
  indicator). Stop FT4 → the radio returns to plain USB/LSB.
- Confirm the transponder audio still routes over the LAN data path (DATA MOD = LAN on the
  radio) and FT4 decodes/transmits as before.
- If data mode still doesn't appear, turn on **Settings → Diagnostics → Diagnostic logs**,
  reproduce, and share the log — look for `setDigitalDataMode(true)` and
  `civ data mode (1A 06)` lines (they confirm what OrbitDeck sent).

### 2. Recording + FT4/SSTV together — independent levels
- Start **Pass recording**, then start **FT4** (or SSTV). Adjust each one's level slider.
  **Good:** each feature's level/meter is independent — changing the recorder level no longer
  changes FT4's audio or makes the FT4 waterfall look strange, and vice-versa.
- Confirm FT4 alone still looks/decodes exactly as it did on your good RS-44 pass.

### 3. Remote voice (unchanged from build 9, still experimental)
- On a network radio, the "Remote audio (voice)" card: Listen + hold-to-talk for an SSB or
  FM voice QSO. Use earphones. Report RX/TX audio and PTT behavior.

## Please report
- IC-9700 not entering USB-D/LSB-D on FT4 (share the `cat` log).
- Recording + decoder levels still interacting, or a strange waterfall when both run.
- Any regression in solo FT4 / SSTV / recording.

## Notes
- The FT4 data-mode sequence (`06` + `1A 06`) is now verified against the IC-9700 CI-V
  Reference Guide and OscarWatch's tested path; this build confirms it on-air.
- Data mode applies to CI-V IC-9700/705/905/7100, Hamlib PKT via rigctld, and Yaesu FT-8x7
  DIG; other radios stay on plain SSB.
- FT4 transmit needs a full-duplex radio or two radios (satellite convention is full duplex
  so you can monitor your own downlink); receiving on any radio is fine.
