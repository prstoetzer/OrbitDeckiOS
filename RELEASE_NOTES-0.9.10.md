# OrbitDeck iOS/iPadOS 0.9.10 — exports, alarms, tools and display polish

Build 1. This release remains below 1.0.

## Summary

0.9.10 rounds out the pass-alarm and exports workflows, adds a satellite-debris compliance tool, and polishes the app's presentation with a proper launch screen, an optional keep-awake Home display, and a consistent iPad reading layout.

## Exports

- Sharing a file now populates the share control under the section you exported from, rather than always under Pass Schedule.
- Pass Schedule can add its passes directly to your calendar (write-only Calendar access is requested only when you first use it).
- Pass Schedule can export **all favorite satellites** in one file, in addition to the selected satellite.

## Pass alarms

- Every place an upcoming pass is listed now offers an unobtrusive reminder control, including **Daily Schedule** and **Sky at a Glance**.
- Where no reminder is available because the pass is in progress or past, a small "no reminder" icon holds the alarm bell's place so rows stay aligned.
- Home "upcoming favorite passes" and "next passes" rows are aligned whether or not a bell is present.
- Tapping a pass reminder notification opens the Home screen.

## Tools

- New **Debris mitigation compliance** calculator (Satellite & orbit): estimates a spacecraft's post-mission orbital lifetime from its physical ballistic coefficient (perigee/apogee altitude, mass, cross-sectional area, drag Cd, solar activity) and checks the legacy 25-year and current FCC 5-year deorbit rules. Pairs with the existing **Cross-section area** tool for the drag area input.
- Removed the redundant tool-count caption from the Tools screen.

## Display

- Added a launch screen so the app opens on its dark background instead of a white flash.
- New **Keep screen awake on Home** setting (Settings ▸ Display): prevents auto-lock while the Home screen is showing so it can serve as a live display during a pass; the rest of the app auto-locks normally, and the setting is released automatically when the app is backgrounded.
- Sky Radar and the OSCARLOCATOR Simulator now update live once per second.
- Reading-oriented screens are capped to a comfortable centered width on iPad; full-bleed visual screens still use the whole pane.

## Other

- Space weather now prefers the hamqsl/N0NBH observed sunspot number used by the ham community, with a NOAA fallback.
- About: the build details section is now labeled "Build info".
