# OrbitDeck for iOS and iPadOS — native port 0.9.7

This tree is a native SwiftUI port of OrbitDeck. It targets **iOS/iPadOS 17+**, **Swift 6**, and uses **SatelliteKit 2.1.2** for SGP4/SDP4 propagation. It does not embed Python/Tkinter.

## Open and build

1. Open `OrbitDeckIOS.xcodeproj` in a current Xcode on macOS.
2. Allow Swift Package Manager to resolve `gavineadie/SatelliteKit` 2.1.2.
3. Select an iPhone/iPad simulator or device running iOS/iPadOS 17 or later.
4. Build and run the `OrbitDeck` scheme.

Location, notifications and Keychain functionality are requested/used only by their associated user-initiated features. QRZ password material is stored in Keychain; Space-Track password material remains session-only.

## 0.9.7 highlights

- Remains deliberately in the **0.9.x** series; source-level feature parity is not a 1.0 declaration.
- Completes the direct desktop feature-gap pass across **EME, Celestial/Sky Map, Conjunctions and Radio**.
- Deepens **Illumination** with the desktop 30-day × 96-phase raster plus orbit-by-orbit and daily eclipse ephemerides.
- Closes **New Launches** add-new-object parity: objects outside the current GP source can be persisted, favorited/selected and refreshed by NORAD from CelesTrak.
- Adds the desktop AO-7 14/30/60-day fitting window and richer fit diagnostics.
- Adds J2 nodal/perigee rates and the calibrated B*-lifetime readout to Orbital Analysis.
- Adds specialist CSV/PDF products for Celestial, EME, Conjunctions, Radio, eclipse ephemerides and New Launches.
- Retains native XLSX, deep Orbital History, full Planning/reporting, the complete 340-current-entity numerical DXCC bridge, 56 Tools, 14 References tables, all eight Astronomy tabs and the **32-case / 13-real-fixture** Tiny BASIC gate.

The 0.9.7 parity audit finds **41/41 desktop destination workflows represented and no known ordinary desktop feature gap**. See `PORTING_STATUS.md` for how desktop omnibus pages are mapped into native iOS destinations and for intentional platform differences.

## Validation boundary

This package is source-validated on a Linux Swift 6 host with parser sweeps, strict-concurrency type checking of the portable engine/service graph, the 0.9.2–0.9.7 runtime regression chain, Tiny BASIC regression, PBX validation and ZIP/source-manifest checks. **It has not been compiled against the Apple iOS SDK in this environment.** SwiftUI, UIKit, Charts, MapKit, notifications and the actual UIKit vector-PDF branches require Xcode validation before release.

See `RELEASE_NOTES-0.9.7.md` and `PORTING_STATUS.md` for detailed parity notes. The CardSat BASIC acceptance fixtures are under `examples/CardSat-BASIC/`.
