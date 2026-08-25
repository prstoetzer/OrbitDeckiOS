# OrbitDeck iOS/iPadOS 0.9.11 — local time, transponder tuning, and accuracy fixes

Build 1. This release remains below 1.0. It follows 0.9.10 (1) and folds in the
0.9.10 (2) fixes.

## Summary

0.9.11 adds a local-time display option, on-Home passband tuning and per-satellite
calibration, and a current-location DXCC/subdivision readout, and fixes several
accuracy and reliability issues in the Ground Track footprint, Daily Schedule,
Workable, and the Home sky plot.

## Time display

- New **Show times in local time** setting (Settings → Display): display every time
  in your device's local zone instead of UTC, honoring your 12/24-hour preference.
  UTC remains the default and Tiny BASIC always uses UTC.
- Pass lists (Daily Schedule, Next Passes, Home upcoming favorites) show the other
  zone as an unobtrusive secondary clock.

## Home transponder

- Linear transponders gain a **passband tuning slider** (centered by default; an
  inverting transponder walks the uplink the opposite way), driving the live RX/TX
  tune readouts.
- An unobtrusive **Calibrate this satellite** expander reveals per-satellite
  downlink/uplink calibration sliders, shared with every Doppler screen and the
  Calibrations editor.
- Sliders whose neutral default is the center now gently snap to center.

## Location & subdivisions

- In current-location mode, your **DXCC entity**, **primary subdivision**
  (state/province) and **secondary subdivision** (county/district) appear on the
  Home Station card, in Settings, and on Grid Finder.
- Subdivisions use LoTW/TQSL names: Connecticut resolves to the legacy county (from
  the town) rather than the new planning region, and the independent cities of
  Virginia, Maryland (Baltimore), Missouri (St. Louis) and Nevada (Carson City) are
  named correctly and distinguished from same-named counties.

## Accuracy & reliability fixes

- **Ground Track footprint** is now geodesically accurate — it is drawn as the true
  0°-elevation boundary instead of a projected circle, so it no longer appears to
  cover stations that are below the horizon.
- **Daily Schedule** opens snapped to the current time, streams passes in as they
  compute (much less lag), and no longer stops partway or gets stuck on
  "Computing…".
- **Workable** "Across next pass" works again, and toggling Live/Across no longer
  flashes the Home screen.
- The **Home** polar sky plot draws reliably when switching satellites, and
  "Upcoming favorite passes" is reliable while following the device location.
- Pass lists and the schedule no longer stall while following the device (they key
  off a coarser, stable position).
- The launch screen no longer flashes white.

## Other

- American English spelling enforced throughout the UI, PDF exports and comments.
