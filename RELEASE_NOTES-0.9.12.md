# OrbitDeck iOS/iPadOS 0.9.12 — post activations to hams.at, Home AMSAT reporting

Build 1. This release remains below 1.0. It follows 0.9.11 (1).

## Summary

0.9.12 lets you **post your own activation alerts to hams.at** from inside
OrbitDeck, adds **one-tap AMSAT status reporting from the Home screen** for every
status type, and fixes accuracy details in the astronomy/sky map. It also
introduces the app's first unit-test target, covering the new hams.at client.

## Post activations to hams.at

- A new **Post an activation to hams.at** button on the Activations screen opens a
  posting form that publishes an upcoming activation alert via the hams.at API
  (`POST /api/alerts`).
- Prefills the satellite, your callsign, station grid and observer position, and
  defaults the pass-maximum time to the selected satellite's next pass.
- **Grid lines and corners** are supported: enter several Maidenhead grids
  (comma-separated) to activate a line (2) or corner (4), with a one-tap button to
  use the grids your station currently claims.
- Enter the observer position as a **Maidenhead grid square** or as
  latitude/longitude.
- Optional operating mode, frequency (up/downlink), comment and on-site chat.
- Your **hams.at API key** (from the hams.at Settings page) is stored in the iOS
  Keychain — enter it in Settings → hams.at or inline on the posting screen.
  OrbitDeck posts only after you confirm; the alert is public and attributed to
  your callsign.

## Home AMSAT status reporting

- A **Report AMSAT status** card on Home reports the selected satellite's status
  with one tap, covering **all** status types (Heard, Telemetry Only, Not Heard,
  Crew Active).
- Resolves the AMSAT catalog/operating name automatically and posts an attributed
  report through the same confirmed path as the full AMSAT status screen.

## Accuracy fixes

- Fixed a flipped azimuth in the Sky Guide / sky map that placed planets (e.g.
  Venus) on the wrong side of the sky (east vs. west).

## Fixes & polish

- NORAD catalog numbers are no longer shown with a thousands separator (comma).

## Under the hood

- Added an **Icom network (LAN/WiFi) CAT control** scope document for a future
  release (IC-9700 / IC-705).
- Added the first app unit-test target with a local hams.at test harness (mock
  server) exercising request building, validation, response parsing and posting.

## Privacy

- The hams.at API key is documented as a Keychain-stored credential; posting an
  activation sends your callsign, grids and observer position to hams.at, where the
  alert is published publicly. See the privacy policy.
