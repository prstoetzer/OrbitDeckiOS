# OrbitDeck iOS/iPadOS 0.9.9 — schedule, calibration and live-tracking refinements

Build 1. This release remains below 1.0.

## Summary

0.9.9 adds a day-by-day operating schedule and a full per-satellite calibration workflow, and refines the live-tracking screens for continuous, once-per-second updates with clearer heading indication.

## Daily Schedule

- New **Daily Schedule** screen (Live/Passes, after Sky at a Glance): every favorite satellite's passes grouped by UTC day and ordered by AOS time.
- Opens on today, scrolls back seven days, and extends automatically into the future as you scroll past the last populated day.
- Tapping a pass selects that satellite.

## Calibration

- Per-satellite radio calibration is now applied to **every** live Doppler readout (Home, Track, Orbital Analysis, Radio link budget, DX Doppler and the Doppler playbook), with an unobtrusive note when it is in effect.
- Calibration follows the CardSat model: a single combined oscillator correction (radio plus satellite), measurable from either the downlink or the uplink. Both offsets fold into the receive dial (uplink sign-flipped for inverting transponders); nothing is added to the transmit dial.
- New **Calibrations** screen (Catalog & Configuration): an editable downlink/uplink table for every satellite — favorites first and searchable — with CSV import and export for bulk entry.

## Live tracking

- Home, Track, Orbital Analysis, Sky Radar, Ground Track and Workable now update once per second; fixed Home updating faster than 1 Hz.
- Polar sky plots mark AOS/LOS and the live position with small direction-of-travel arrows.
- The Ground Track marker and the 3D-globe satellites are drawn as heading arrows; globe satellites sit at a scaled relative altitude.
- Continuous device-location follow drives the observer position; the dedicated **Grid Finder** keeps its own high-precision fix for VUCC grid-line/corner navigation.

## Other

- Space weather now uses NOAA's most recent daily observed sunspot number (previously monthly).
- The menu's refresh control is clarified (it updates orbital element sets / GP) and shows the last-updated time.
- 3D globe time scrubbing extended to ±24 hours.
