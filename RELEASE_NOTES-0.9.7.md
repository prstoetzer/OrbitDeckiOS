# OrbitDeck iOS/iPadOS 0.9.7 — feature-gap completion

Build 16. This release intentionally remains below 1.0.

## Summary

0.9.7 completes the direct desktop feature-gap pass. Every one of the desktop application's 41 destination workflows is now represented natively. Where desktop uses an omnibus screen (notably Orbital Analysis), iOS may expose the same workflow as a dedicated destination instead of duplicating it inside the omnibus view.

This is a **feature-completion milestone**, not a device-release declaration: Apple-SDK/Xcode validation remains outstanding.

## EME

- Adds the desktop seven-frequency operating picker: 50.2, 144.1, 222.1, 432.1, 1296, 2304.1 and 10368.1 MHz.
- Adds Moon declination, path degradation from reference perigee, Moon/Sun separation and low-elevation ground-gain indication.
- Adds the desktop five-band comparison (50/144/432/1296/10368 MHz): self-echo Doppler, approximate Faraday rotation, sky temperature behind the Moon, libration spread and two-way path loss.
- Adds the 90-day noon-UTC planning table and the desktop good-day criterion (`declination > +15°` and path degradation `< 1 dB`).
- Retains 24/48/72-hour common-Moon visibility planning and adds specialist CSV/PDF output.

## Celestial and Sky Map

- Completes the desktop fixed radio-source roster with Orion A, Centaurus A and Fornax A.
- Adds the desktop cold-sky reference direction.
- Adds the selected satellite to the Celestial/Sky Map body roster.
- Adds Celestial table CSV and printable PDF sharing.

## Conjunctions

- Pair screening now exposes detailed time-of-closest-approach geometry: miss distance, relative velocity, both spacecraft altitudes/speeds and the local separation-rate derivative.
- Adds a ±10-minute separation curve around TCA.
- Neighborhood mode now scans the complete loaded catalog rather than using a semi-major-axis prefilter.
- Adds pair CSV/PDF and neighborhood CSV output.
- Keeps the desktop safety contract explicit: public GP screening is for awareness, not operational collision avoidance.

## Radio

- Replaces the earlier live-Doppler foundation with the desktop's three operating workflows: **Link budget**, **Doppler playbook**, and **Passband plan**.
- Adds a shared next-pass picker and AOS→LOS time scrubber with TCA snap.
- Adds editable ground-station and satellite link-budget assumptions.
- Adds selectable position across a linear transponder passband.
- Adds 30/60/120-second Doppler playbooks with FM independent correction and full-duplex fixed-downlink/fixed-uplink round-trip rules.
- Adds CSV and printable PDF playbooks plus a 0–100% passband dial-pair table.
- No iOS-only CAT/rig transport was invented: desktop OrbitDeck's Radio destination is itself a planning/playbook workflow.

## Illumination

- Adds the desktop **30-day × 96-samples-per-orbit** illumination raster with 7-day back/forward navigation and Today reset.
- Adds the desktop-style 1/3/7/14-day satellite eclipse ephemeris.
- Eclipse intervals are refined to approximately one-second transition resolution from the same Earth-shadow test used by live tracking.
- Adds daily eclipse count, total, longest interval, percent of UTC day and beta angle.
- Adds eclipse CSV/PDF and retains the 60-day illumination PDF.

## AO-7

- Adds 14/30/60-day AMSAT report-fit windows.
- Adds explicit time-to-switch, total reports and observed mode-change count alongside agreement and phase uncertainty.
- Continuous-sunlight gating remains mandatory before the timer fit is treated as meaningful.

## Orbital Analysis

- Adds J2 node regression and perigee-precession rates.
- Adds the calibrated B*-anchored lifetime estimate.
- The desktop omnibus pages for live geometry, next passes, ground track, Doppler, illumination/outlook and EQX remain intentionally decomposed into the native Track, Passes/Pass Detail, Ground Track, Radio, Illumination/Pass Progression and OSCARLOCATOR/Exports destinations.

## New Launches

- A discovered object outside the current GP catalog can now be **added to My Satellites**, selected and favorited immediately.
- The CelesTrak OMM record already returned by the scan seeds the object; SatNOGS transmitters are carried with it.
- Extra objects persist as last-known element snapshots and their NORAD IDs are refreshed from CelesTrak during the normal GP-update workflow.
- Adds scan-result CSV/PDF output.

## Validation

Portable/source validation performed for 0.9.7:

- 39/39 application Swift files parse.
- 39/39 Swift files have PBX file references and Sources-phase entries.
- `project.pbxproj` passes `plutil` validation.
- Portable engine/service/export graph passes Swift 6 strict-concurrency type checking.
- Current-tree 0.9.2, 0.9.3, 0.9.4, 0.9.5, 0.9.6 and 0.9.7 runtime smokes pass.
- 0.9.7 specialist smoke: 5 EME bands, 90-day plan, 17-object Celestial roster, 41-point conjunction curve, 11-row Radio playbook, 11-position passband plan, eclipse ephemeris/daily summary and persistent extra-satellite construction.
- Tiny BASIC remains 32/32 with 13 real CardSat fixtures.
- Pre-0.9 preference JSON still decodes with the new optional extra-satellite storage absent.
- Versioning is 0.9.7 / build 16 and network User-Agent strings are synchronized.

## Remaining boundary

A real Xcode/iOS SDK build has **not** been executed on this Linux host. SwiftUI/UIKit/Charts/MapKit layout, Core Location, notifications, Keychain, share-sheet behavior, device size classes/accessibility and the actual UIKit vector-PDF rendering branches require simulator/device validation on macOS before release. Those are validation/platform tasks, not known missing desktop workflows.
