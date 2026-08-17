//
//  OrbitDeckScreenshots.swift
//  OrbitDeckUITests
//
//  App Store screenshot automation for OrbitDeck.
//
//  This test launches the app and walks the sidebar (NavigationSplitView) to
//  each "hero" screen, capturing a full-screen screenshot of every one. It works
//  on both iPhone (compact — the split view collapses to a stack, so we pop back
//  to the sidebar between shots) and iPad (regular — sidebar selection updates the
//  detail in place, no back navigation needed).
//
//  Two capture modes are supported:
//
//   1. Standalone (default): screenshots are stored in the .xcresult bundle as
//      attachments. Extract them to PNGs afterward with `xcparse` (see the
//      instructions at the bottom of this file).
//
//   2. fastlane snapshot: add fastlane's SnapshotHelper.swift to this target and
//      flip `useFastlaneSnapshot` to true. fastlane then writes correctly named
//      PNGs to disk, one folder per simulator/locale — the standard App Store flow.
//
//  Screens were chosen to showcase OrbitDeck's range; edit `shots` to taste.
//

import XCTest

final class OrbitDeckScreenshots: XCTestCase {

    /// Set true after adding fastlane's SnapshotHelper.swift to this target.
    /// Then `capture(_:)` routes through fastlane's `snapshot(_:)`.
    private let useFastlaneSnapshot = false

    /// The sidebar screens to capture, in order. The label must match the
    /// visible sidebar title in OrbitDestination.title exactly.
    private let shots: [(name: String, sidebarLabel: String)] = [
        ("01-Home",         "Home"),
        ("02-SkyRadar",     "Sky Radar"),
        ("03-GroundTrack",  "Ground Track"),
        ("04-NextPasses",   "Next Passes"),
        ("05-OrbitalAnalysis", "Orbital Analysis"),
        ("06-Radio",        "Radio"),
        ("07-OSCARLOCATOR", "OSCARLOCATOR Sim"),
        ("08-SpaceWx",      "Space Wx"),
        ("09-Tools",        "Tools"),
    ]

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()

        if useFastlaneSnapshot {
            // setupSnapshot(app) — provided by fastlane's SnapshotHelper.swift.
            // Uncomment the next line once SnapshotHelper.swift is in this target:
            // setupSnapshot(app)
        }

        // A hint the app can honor to seed demo data / skip permission prompts.
        // (Harmless if the app ignores it.)
        app.launchArguments += ["-uitest", "1"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func testCaptureAppStoreScreenshots() throws {
        for shot in shots {
            navigate(to: shot.sidebarLabel)
            // Give async data (propagation, charts, maps) a moment to render.
            usleep(1_500_000) // 1.5s
            capture(shot.name)
        }
    }

    // MARK: - Navigation

    /// Selects a sidebar destination by its visible title, resilient to the
    /// compact (iPhone) vs. regular (iPad) split-view behaviors.
    private func navigate(to label: String) {
        let target = sidebarElement(label)

        // On iPhone the detail is pushed over the sidebar. If the target row
        // isn't reachable, pop back until the sidebar (and the row) is visible.
        var attempts = 0
        while !target.exists || !target.isHittable {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable {
                back.tap()
                usleep(400_000)
            } else {
                break
            }
            attempts += 1
            if attempts > 6 { break }
        }

        XCTAssertTrue(target.waitForExistence(timeout: 8),
                      "Could not find sidebar item '\(label)'")
        target.tap()
    }

    /// Locates a sidebar row by label across the element types SwiftUI may vend
    /// for a selectable List row (button / cell / static text).
    private func sidebarElement(_ label: String) -> XCUIElement {
        let byButton = app.buttons[label]
        if byButton.exists { return byButton }
        let byCell = app.cells[label]
        if byCell.exists { return byCell }
        let byCellText = app.cells.staticTexts[label]
        if byCellText.exists { return byCellText }
        // Fall back to any static text with this label (last resort).
        return app.staticTexts[label]
    }

    // MARK: - Capture

    private func capture(_ name: String) {
        if useFastlaneSnapshot {
            // snapshot(name) — provided by fastlane's SnapshotHelper.swift.
            // Uncomment once SnapshotHelper.swift is in this target:
            // snapshot(name)
            return
        }
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/*
 ────────────────────────────────────────────────────────────────────────────
 SETUP
 ────────────────────────────────────────────────────────────────────────────

 1. Add a UI Testing target in Xcode (I can't edit the .xcodeproj safely):
      File ▸ New ▸ Target… ▸ "UI Testing Bundle"
      Product Name: OrbitDeckUITests
      Target to be Tested: OrbitDeckIOS
    Then add THIS file to that target (drag it into the new group, or set its
    Target Membership to OrbitDeckUITests in the File Inspector).

 2. Prepare the simulator state ONCE before running so screens aren't empty:
      • Launch the app manually, allow Location, add a few favorite satellites
        (ISS, AO-91/RS-44, a GEO bird), and let GP/transponder data download.
      • Screenshots reflect whatever state the simulator is in.

 3. Run the screenshot test on each App Store device size:
      xcrun simctl boot "iPhone 16 Pro Max"      # 6.9"  (1320 x 2868)
      xcrun simctl boot "iPad Pro 13-inch (M4)"  # 13"   (2064 x 2752)

      xcodebuild test \
        -project OrbitDeckIOS.xcodeproj \
        -scheme OrbitDeckIOS \
        -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
        -only-testing:OrbitDeckUITests/OrbitDeckScreenshots \
        -resultBundlePath build/iphone.xcresult

      (repeat with the iPad destination and -resultBundlePath build/ipad.xcresult)

 4. Extract the PNGs from the result bundle:
      brew install chargepoint/xcparse/xcparse   # one-time
      xcparse screenshots build/iphone.xcresult ~/Desktop/OrbitDeckShots/iPhone
      xcparse screenshots build/ipad.xcresult   ~/Desktop/OrbitDeckShots/iPad

    The PNGs are already at native device resolution — upload directly in
    App Store Connect (6.9"/6.7" iPhone set + 13" iPad set).

 ────────────────────────────────────────────────────────────────────────────
 OPTIONAL: fastlane snapshot (auto-named PNGs, multi-device, one command)
 ────────────────────────────────────────────────────────────────────────────

   • Add fastlane's SnapshotHelper.swift to this UI test target:
       https://github.com/fastlane/fastlane/blob/master/snapshot/lib/assets/SnapshotHelper.swift
   • Set `useFastlaneSnapshot = true` above and uncomment the setupSnapshot(app)
     and snapshot(name) lines.
   • Create fastlane/Snapfile (see the Snapfile I wrote alongside this file).
   • Run:  fastlane snapshot
     fastlane loops the devices in Snapfile and writes named PNGs to
     ./fastlane/screenshots/<locale>/<device>-<name>.png automatically.
 */
