# TestFlight — OrbitDeck 0.9.14 (6) · What to Test

This build focuses on **satellite FT4** Doppler handling. The audio-domain Doppler
correction is now on by default, the transmit correction was fixed for inverting
transponders, and transmissions now start on time. Please exercise FT4 on a linear bird and
report back.

## Headline changes
- **RX & TX audio Doppler correction now default ON** (were experimental/off).
- **TX Doppler fixed on inverting transponders** — the correction had the wrong sign on
  inverting birds, which made you drift/smear to others. Now sideband-aware.
- **On-time transmissions** — TX slots used to start up to ~0.8 s late (bad "dT" to other
  stations). A new pre-arm keys up in the dead air before the slot so bursts start on time.

## Setup
1. Configure your CAT radio and a linear transponder for the satellite (Home card).
2. Open FT4. Confirm the Doppler readout line shows DL/UL shift and a Hz/s rate.
3. Both "Doppler-correct RX audio" and "Doppler-correct TX audio" should be **ON** by default.

## What to test

### 1. RX decoding (primary)
- Decode FT4 during a pass, ideally near TCA (highest Doppler rate).
- **Good:** steady stream of decodes across the whole pass, including the fast-Doppler
  minutes around closest approach.
- Try toggling "Doppler-correct RX audio" off mid-pass — decodes should get noticeably worse
  near TCA, confirming the correction is doing its job.

### 2. Transmit / QSO — **inverting vs non-inverting birds**
- Run an auto-sequenced QSO (tap a decode, or Call CQ).
- **On an inverting linear transponder** (RS-44, most CAS/XW birds, AO-7 mode B): the most
  important case. Ask another station whether your signal holds a steady frequency or drifts
  across the ~5 s burst. **Good = steady.** Report the satellite name either way.
- **On a non-inverting bird:** confirm behavior is unchanged (still steady).
- If you have full-duplex, confirm you can **decode your own signal**.

### 3. Slot timing (dT)
- Ask a station receiving you (or WSJT-X) for your **dT**. Should be well under a few tenths
  of a second, not ~0.8 s.
- Note there is now a brief (~0.5 s) carrier before each burst as the radio keys up early —
  expected. Tell me if it feels too long on the transponder.

### 4. PTT / sequencing (regression)
- Confirm PTT keys and unkeys cleanly every TX slot, and always releases when you Stop FT4 or
  a QSO completes (send 73). **No stuck PTT.**
- Confirm the CAT dial holds steady within each slot and steps only at slot boundaries.

### 5. PSKReporter (opt-in, if enabled)
- With reporting on + callsign/grid set, confirm your received stations appear on
  pskreporter.info at roughly the correct downlink frequency.

## What "bad" looks like — please report
- Missed decodes near TCA, or worse than a previous build.
- Others reporting you drift/smear (note the satellite + whether it's inverting).
- dT ≳ 0.5 s, or transmissions starting late/getting cut off.
- Stuck PTT, or PTT keying while the radio is on the wrong band.
- Audio dropouts on RX or TX.

## Diagnostics
The debug log (category `ft4`) records each transmission's dT, e.g.
`FT4 TX dT=+0.12s (pre-armed) · "N8HM ..."` — include a snippet if you hit timing issues.

## Not in this build
Half-duplex FT4 (single-radio rigs like the IC-705) is **not** included — it's planned
(see `SCOPE_HALFDUPLEX_FT4.md`). This build still requires a full-duplex or two-radio setup
for FT4 transmit.
