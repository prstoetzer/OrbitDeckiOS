# App Privacy (App Store Connect) — OrbitDeck 1.1

Sources: `docs/privacy.html` (updated November 21, 2026), the root `PrivacyInfo.xcprivacy`, and the code (grepped where noted). App Store Connect → the app → **App Privacy** → Edit. The label applies to the app as a whole and changes as soon as you publish it, so publish it together with (or just before) submitting 1.1.

## How "collect" applies to OrbitDeck

Apple defines *collect* as transmitting data off the device so that you **or your third-party partners** can access it longer than needed to service the request in real time. The developer runs no servers and receives nothing. But in 1.1 the app itself sends some personal data directly to outside services it integrates, and several of them **retain and publish** it:

- status.amsat.org (status reports: your callsign and grid, published),
- hams.at (activation alerts: callsign, grids and observer position, published),
- PSKReporter (opt-in FT4 spots: your callsign and grid, published),
- APRS-IS (Nearby & DX: callsign login plus a position filter at about 100 m; opt-in satgate: callsign login plus gated packets, redistributed publicly),
- DX cluster (callsign login),
- Open-Meteo (station position rounded to about 1 km, no identity),
- LoTW and Cloudlog/Wavelog (QSO records you upload),
- QRZ (your QRZ user name and the callsigns you look up).

**Recommendation (conservative):** treat these integrated services as third-party partners and declare the data types below. Everything is optional, user-initiated and for app functionality, so the label stays modest. The alternative reading (the services are the user's own chosen accounts, so "Data Not Collected") is arguable for LoTW/QRZ/Cloudlog, but not for AMSAT/hams.at/PSKReporter/APRS-IS, which the app integrates and which publish what it sends. Under-declaring is the riskier error (guideline 5.1.1/5.1.2 and the privacy-label accuracy requirement).

## Answers

**Do you or your third-party partners collect data from this app?** → **Yes, we collect data from this app.**

| Data type (ASC category) | Collected | Linked to the user | Used for tracking | Purposes | Why |
|---|---|---|---|---|---|
| **Location → Precise Location** | Yes | **Yes** | No | App Functionality | APRS-IS position filter is sent to three decimal places (Apple's threshold for "precise") together with the callsign login; hams.at alerts carry the observer position with your callsign. (Device location for predictions itself stays on the device and isn't "collected".) |
| **Location → Coarse Location** | Yes | **Yes** | No | App Functionality | Open-Meteo receives the position rounded to ~1 km (not linked by itself); grid squares go to status.amsat.org and PSKReporter with your callsign, which makes the type linked overall. |
| **Identifiers → User ID** | Yes | Yes | No | App Functionality | The amateur callsign is a public handle that identifies the operator; it is sent to AMSAT status, hams.at, PSKReporter, APRS-IS and DX cluster logins. |
| **User Content → Other User Content** | Yes | Yes | No | App Functionality | QSO log records uploaded to LoTW or Cloudlog/Wavelog; AMSAT status reports; hams.at activation alerts; PSKReporter reception reports. |
| Contact Info (Name, Email, Phone, Address, Other) | No | | | | Nothing sent as contact info. The Space-Track "identity" may be an email address, but it is sent only as the login for the user's own Space-Track account (see owner decisions). |
| Health & Fitness, Financial Info, Sensitive Info, Contacts | No | | | | Not used. |
| User Content → Emails or Text Messages | No | | | | APRS messages go over the air by radio, not to a service. (The satgate forwards *other stations'* heard packets, not the user's messages; the user's own packets are never gated.) |
| User Content → Photos or Videos, Audio Data, Gameplay, Customer Support | No | | | | SSTV images, recordings and voice memos stay on the device; audio is decoded on-device (including DeepCW) and never uploaded. Remote voice goes only to the user's own radio on the LAN. |
| Browsing History, Search History | No | | | | |
| Identifiers → Device ID | No | | | | No IDFA, no IDFV use, no ATT prompt. |
| Purchases | No | | | | Free, no IAP. |
| Usage Data (Product Interaction, Advertising Data, Other) | No | | | | No analytics SDKs. |
| Diagnostics (Crash Data, Performance Data, Other Diagnostic Data) | No (see note) | | | | The diagnostic log stays on the device. The user may share it by email; that is optional, infrequent and user-initiated, which fits Apple's optional-disclosure exception. Apple's own crash reports (TestFlight / opted-in analytics) are not the developer's collection. |
| Other Data | No | | | | |

**Tracking:** No data type is used for tracking. The app has no ads, no data brokers, no ATT prompt (`NSPrivacyTracking` stays `false`, `NSPrivacyTrackingDomains` stays empty).

**Resulting label:** "Data Linked to You: Location, Identifiers, User Content". No "Data Used to Track You". No "Data Not Linked to You" section (all four types are linked).

### Owner decisions

1. **Linked vs. not linked for location.** 1.0's manifest says Precise Location is *not* linked. In 1.1 the APRS-IS filter and hams.at alerts send position together with the callsign, so "linked" is the accurate answer. If you'd rather keep Precise Location "not linked", you'd need to argue that the callsign isn't identity, which conflicts with declaring User ID.
2. **Space-Track login email.** Recommended: not declared (it's a credential for the user's own account, sent only to authenticate). Conservative alternative: declare **Contact Info → Email Address**, linked, App Functionality.
3. **Diagnostics.** Recommended: not declared (optional user-initiated sharing). Conservative alternative: declare **Diagnostics → Other Diagnostic Data**, linked (the email comes from the user), App Functionality.
4. **Minimal reading.** If you decide integrated public services aren't "third-party partners", the answer becomes "Data Not Collected". Not recommended for 1.1 because of the publishing services above.

## PrivacyInfo.xcprivacy changes to match (do not apply here)

The manifest in the app target is the **root** `PrivacyInfo.xcprivacy` (it's in the OrbitDeckIOS target's Resources phase; there is no `OrbitDeckIOS/PrivacyInfo.xcprivacy`). The widget extension has no manifest and needs none: it doesn't call any required-reason API and collects nothing (no `UserDefaults` or file-attribute calls in `OrbitDeckWidgets/`).

Replace the `NSPrivacyCollectedDataTypes` array (and update its comment) with:

```xml
    <!-- Data types collected. The developer receives nothing; these are sent from the
         device, only when the user uses the feature, to services the app integrates
         that retain or publish them: the callsign (User ID) to status.amsat.org,
         hams.at, PSKReporter, APRS-IS and DX clusters; position to APRS-IS (filter,
         ~100 m) and hams.at (precise), Open-Meteo (~1 km) and grid squares to AMSAT
         and PSKReporter (coarse); QSO records, status reports and activation alerts
         (other user content) to LoTW, Cloudlog/Wavelog, AMSAT and hams.at.
         Nothing is used for tracking. -->
    <key>NSPrivacyCollectedDataTypes</key>
    <array>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypePreciseLocation</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <true/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeCoarseLocation</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <true/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeUserID</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <true/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyCollectedDataType</key>
            <string>NSPrivacyCollectedDataTypeOtherUserContent</string>
            <key>NSPrivacyCollectedDataTypeLinked</key>
            <true/>
            <key>NSPrivacyCollectedDataTypeTracking</key>
            <false/>
            <key>NSPrivacyCollectedDataTypePurposes</key>
            <array>
                <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
            </array>
        </dict>
    </array>
```

If you take owner decision 2 or 3, add `NSPrivacyCollectedDataTypeEmailAddress` or `NSPrivacyCollectedDataTypeOtherDiagnosticData` entries in the same shape. The manifest must match the App Store Connect answers; Xcode's privacy report (Organizer → archive → right-click → Generate Privacy Report) shows the merged result for checking.

## Required-reason APIs

Declared in the root manifest today:

| Category | Reason | Use found in code | Status |
|---|---|---|---|
| `NSPrivacyAccessedAPICategoryUserDefaults` | CA92.1 (app-only access) | `UserDefaults` / `@AppStorage` in 20 app files (settings, feed timestamps, approvals). No App Group suite, so CA92.1 is right. The widget doesn't use UserDefaults. | Correct |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | C617.1 (files in the app container) | `DebugLog.swift:72` (`attributesOfItem`, log rotation); **new in 1.1:** `FeatureEngine.swift:3525` (modification date of the cached hams.at feed in Caches) and `UtilityEngine.swift:590-593` (`contentModificationDateKey` to sort Notes in Documents/Notes). All are inside the app container, so C617.1 still covers them. | Correct; consider updating the manifest comment to mention the hams.at cache and Notes (comment only) |

Not used (no declaration needed), checked by grep over `OrbitDeckIOS/` and `OrbitDeckWidgets/` (Swift, C and headers, including ft8_lib):

- **System boot time** (`systemUptime`, `mach_absolute_time`, `kern.boottime`): not called. `DispatchTime.now().uptimeNanoseconds` is used for CAT/Icom timeouts (`CATTransport.swift`, `IcomNetwork.swift`); it measures elapsed intervals and isn't one of the APIs Apple lists. If Apple's upload check ever flags it, the matching reason would be 35F9.1 (measure elapsed time between in-app events).
- **Disk space** (`volumeAvailableCapacity…`, `systemFreeSize`, `statfs`): not used.
- **Active keyboards** (`activeInputModes`): not used.

Third-party code: SatelliteKit (SPM) has no privacy manifest and uses none of these APIs; ft8_lib and the bundled DeepCW Core ML model don't either. Neither is on Apple's list of SDKs that require their own manifest.
