# TestFlight — OrbitDeck 0.9.14 (11) · What to Test

This build comes out of the OscarWatch cross-audit: two confirmed CAT defects fixed, more
rotator protocols, Doppler-tracking refinements, a manual-tuning frequency readout, a
recalibrated FT4 signal report, and automatic transponder calibration.

## Headline changes
- **Narrow FM on FM satellites.** FM birds (SO-50 etc.) are now commanded in **FM-N** (the rig
  picks its narrow FM filter) instead of wide FM. On/off in Settings ▸ CAT ▸ Tuning.
- **Kenwood TS-2000 / TS-790 satellite mode.** These now enter the radio's **SATL** mode with
  the proper Main=downlink / Sub=uplink split handshake (previously they were driven as a plain
  dual-VFO radio and never entered sat mode).
- **Doppler refinements.** Extra predictive lead on the outbound (receding) half of a pass; a
  short **dial settle/resume** window so CAT doesn't fight you when you tune (tighter than the
  desktop trackers — 250 ms RX / 700 ms uplink, adjustable); a band-plausibility guard on
  follow-dial reads.
- **More rotators.** Added **SAEBRTrack** (serial) and **OZ9AAR URC** (TCP/JSON) plus an
  optional **slew lead** (aim ahead of the satellite by N seconds for mechanical lag).
- **Tune-here readout on FT4 & SSTV.** A live Doppler-corrected **RX/TX MHz** line for operating
  without CAT — set your radio by hand from it.
- **FT4 signal report recalibrated.** Reports read much lower/more realistic (the noise floor was
  being measured across the empty filter skirts, inflating every SNR). Compare to WSJT-X.
- **Automatic transponder calibration (opt-in).** While you transmit FT4 full duplex, OrbitDeck
  measures where your own signal comes back vs your TX audio frequency and refines this
  satellite's saved calibration on every self-decode.

## What to test

### 1. Narrow FM on an FM satellite (IC-9700)
- Work an FM bird (SO-50) with the IC-9700. **Good:** the radio shows **FM-N** (narrow) on both
  legs, not wide FM. If the filter looks wrong, toggle **Settings ▸ CAT ▸ Tuning ▸ Narrow FM on
  FM satellites** off to compare, and tell me which FM filter it selected.

### 2. Kenwood TS-2000 / TS-790 satellite mode (if you have one)
- Connect the TS-2000, start a linear pass. **Good:** the radio enters **satellite (SATL)** mode,
  downlink on Main / uplink on Sub, and both legs track Doppler. On disconnect it should leave
  SATL. (Untested on hardware — please report.)

### 3. IC-9700 RS-44 linear pass — Doppler feel
- Run a normal RS-44 pass. **Good:** tracking still locks like before, and feels a touch tighter
  on the *outbound* half. If you turn the dial (with "Follow radio tuning" on), CAT should pause
  briefly then resume rather than fight you.

### 4. Rotator (if you have one)
- SAEBRTrack or OZ9AAR URC users: pick the protocol and confirm pointing. Optional **slew lead**
  (Settings ▸ Rotator ▸ Pointing) aims a few seconds ahead — useful on fast overhead passes.
  (Green Heron RT-21 is intentionally not offered — it needs two independent serial links.)

### 5. Tune-here frequency readout (no CAT needed)
- On the FT4 and SSTV Home cards, below az/el there's now a **Tune  RX … · TX … MHz** line that
  tracks Doppler live. Set a manually-tuned radio from it and confirm it lands you on the signal.

### 6. FT4 signal report vs WSJT-X (please compare!)
- Decode the same FT4 signals in OrbitDeck and WSJT-X (or judge against known-good reports).
  **Good:** OrbitDeck's dB reports are now in the same ballpark as WSJT-X (they used to read
  high). Tell me if they're now too **low** or still too **high** — the calibration is easy to
  nudge.

### 7. Automatic transponder calibration (opt-in)
- Turn on **Settings ▸ Audio features ▸ Auto-calibrate transponder from FT4**. Transmit FT4 full
  duplex on a linear bird. **Good:** each time you decode your **own** signal, the satellite's
  saved calibration nudges so your downlink recenters and your own signal sits at your TX audio
  frequency. Watch the `ft4` diagnostic log for `auto-cal` lines. It's damped/clamped, so it
  should converge over a few of your transmissions, not jump.

## Please report
- FM-N: which filter the 9700 actually selected on an FM bird.
- TS-2000: whether it entered SATL and tracked correctly.
- FT4 report numbers next to WSJT-X for the same signals.
- Auto-cal: whether it converged sensibly (and didn't wander) on a good pass.

## Notes
- Narrow-FM filter byte is `06 05 02` (FIL2) on the IC-910/9100/9700; other rigs stay on plain FM
  (narrow FM there is a rig menu setting).
- Auto-calibration edits the per-satellite calibration on the Calibrations screen; it's off by
  default and only runs on linear transponders while you transmit.
