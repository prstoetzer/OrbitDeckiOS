# OrbitDeck 1.1 — App Store submission package

App: **OrbitDeck** (iOS/iPadOS), bundle ID `com.prstoetzer.OrbitDeckIOS`, widget extension `com.prstoetzer.OrbitDeckIOS.OrbitDeckWidgets`, team `A4KV683T6U`, category Utilities, free, MIT. Live on the App Store as **1.0 (18)**. This package is for **1.1 (5)**.

Work through the sections in order. Each `.txt` file in this folder is paste-ready (plain text, no Markdown; App Store fields don't render it).

## Files and character counts

Counted with `python3 -c "print(len(open(f, encoding='utf-8').read().rstrip('\n')))"` (Unicode characters, trailing newline excluded; App Store Connect counts characters, not bytes). Recount after any edit.

| File | App Store Connect field | Limit | Count |
|---|---|---|---|
| `whats-new.txt` | What's New in This Version | 4000 | **3451** |
| `promotional-text.txt` | Promotional Text (editable any time, no review) | 170 | **159** |
| `description.txt` | Description | 4000 | **3963** |
| `keywords.txt` | Keywords | 100 | **100** (no spaces after commas) |
| `subtitle.txt` | Subtitle (App Information) | 30 | **27** |
| `review-notes.txt` | App Review Information → Notes | 4000 | **3892** |
| `testflight-what-to-test.txt` | TestFlight → build → Test Details → What to Test | 4000 | **2712** |
| `urls.md` | Support, Marketing and Privacy Policy URLs | | |
| `app-privacy.md` | App Privacy questionnaire + manifest snippet + required-reason APIs | | |
| `age-rating.md` | Age Rating questionnaire | | |
| `export-compliance.md` | Encryption / export compliance | | |
| `ExportOptions.plist` | `xcodebuild -exportArchive` options (app-store-connect, upload, symbols) | | |

Keywords deliberately avoid words already in the name or subtitle (OrbitDeck, ham, radio, satellite, station; Apple indexes those already and matches plurals) and avoid trademarks and other apps' names (AMSAT, LoTW, SatPC32, Gpredict…, guideline 2.3.7). Subtitle alternatives if you prefer: "Amateur Satellite Tracker" (25), "Satellite Tracking & Doppler" (28).

---

## 1. Pre-flight

### Build number
- `CURRENT_PROJECT_VERSION` is **5** and `MARKETING_VERSION` is **1.1** for the app, widget and test targets (set with Xcode's build-setting tools). Confirm in Xcode → each target → General → Identity before archiving. The app and its extension must have the same version and build or the upload is rejected. Don't edit the pbxproj by hand (CLAUDE.md).
- App Store Connect rejects a build number already uploaded for 1.1 (builds 1–4 were TestFlight builds per `RELEASE_NOTES-1.1.md`), so archive only after the bump.

### Merge and repo state
- [ ] `main` is clean and pushed (`git status`, `git log origin/main..main` empty). At writing, `main` = `origin/main` at 73ad63a, and `pr-9` is fully merged.
- [ ] The parallel docs/README/release-notes/screenshot work is committed and pushed, and the `docs/` site is live (App Review opens the privacy and support URLs). See `urls.md`.
- [x] `PrivacyInfo.xcprivacy` updated to match `app-privacy.md` (Precise/Coarse Location, User ID, Other User Content; all linked, App Functionality, no tracking). Enter the same answers in App Store Connect.
- [ ] Optional: tag the release after upload (`git tag v1.1-5 && git push --tags`).

### Tests
- [ ] Xcode → scheme **OrbitDeckIOS** → Product → Test (⌘U) on an iOS 26.5+ simulator (the test target's deployment target is 26.5), or:
  `xcodebuild test -project OrbitDeckIOS.xcodeproj -scheme OrbitDeckIOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (use a simulator you have installed).
- [ ] All tests pass (commit 1c93556 made them pass under Xcode 27.2; re-run after the DeepCW, transmit-safety and logbook commits).
- [ ] A Release build runs on a physical device on iOS 17 (app minimum) and iOS 18+ (Live Activity minimum).

### Hardware verification (from RELEASE_NOTES-1.1.md, "Still to verify on hardware")
Tick what you've verified; anything left unverified should stay out of marketing claims (none of the text in this folder claims hardware verification).
- [ ] CAT: IC-705 Bluetooth re-test
- [ ] CAT: FM-D / PKT data modes
- [ ] CAT: IC-9700 satellite mode off on disconnect
- [ ] CAT: satellite rigs as two-radio legs
- [ ] CAT: receive-only layout / Beacon
- [ ] CAT: Kenwood OM0/MD and TS-590 TN
- [ ] CAT: rigctld VFO mode
- [ ] Servers with real Gpredict / WSJT-X (client approval, network PTT)
- [ ] Rotator: SPID reply format, read-back, self-test (and retry after failure)
- [ ] Packet 9600 interoperability
- [ ] CW decoder (DeepCW and Classic) on a real downlink
- [ ] FT4 subtraction / deep decode / DT on air; RF-power read per rig; Tune keying
- [ ] SSTV thresholds and M3/M4/S3/S4 on air
- [ ] LoTW upload with subdivisions / IOTA
- [ ] Live Activity while closed: runs through a pass and moves on at LOS with the app suspended
- [ ] Live Activity background refresh; scheduled start (iOS 26)
- [ ] Single activity after reopen/relaunch; renewal after 4 h
- [ ] Live Activity layouts on small/large phones and with another app sharing the island; Apple Watch Smart Stack
- [ ] Transmit safety (commit 5e2d870): Stop / Stop all / disconnect / link drop unkey every mode
- [ ] Background audio with the built-in mic, following `review-notes.txt` exactly, on a physical iPhone **and** iPad (1.0 was rejected under 2.5.4 on an iPad Air)

---

## 2. Archive and upload

### Xcode (recommended)
1. Select scheme **OrbitDeckIOS** and destination **Any iOS Device (arm64)**.
2. Confirm Signing & Capabilities for both OrbitDeckIOS and OrbitDeckWidgetsExtension: **Automatically manage signing**, team **A4KV683T6U**.
3. Product → **Archive**. The Organizer opens when it finishes.
4. Select the 1.1 (5) archive → **Validate App** (optional but catches signing/plist issues) → **Distribute App** → **App Store Connect** → **Upload**. Keep "Upload your app's symbols" on and automatic signing. Don't let Xcode change the build number.
5. Wait for "Upload Successful".

### Command line alternative
```sh
cd /Users/prstoetzer/Documents/Development/OrbitDeck-iOS-0.9.7
xcodebuild archive \
  -project OrbitDeckIOS.xcodeproj -scheme OrbitDeckIOS -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/OrbitDeck-1.1-5.xcarchive \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/OrbitDeck-1.1-5.xcarchive \
  -exportOptionsPlist AppStore-1.1/ExportOptions.plist \
  -exportPath build/OrbitDeck-1.1-5-export \
  -allowProvisioningUpdates
```
`ExportOptions.plist` uses `method = app-store-connect`, `destination = upload` (uploads directly; change to `export` to get an .ipa and upload it with Transporter instead), `teamID = A4KV683T6U`, automatic signing, `uploadSymbols = true`, `manageAppVersionAndBuildNumber = false`. Uploading needs an Xcode-signed-in Apple ID with access to the team, or add `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` for an App Store Connect API key.

---

## 3. Processing and TestFlight
1. App Store Connect → OrbitDeck → **TestFlight**. The build shows "Processing" (usually 5–30 min); you get an email when done. Watch for an ITMS warning email (missing purpose string, privacy manifest, etc.).
2. Export compliance should not be asked (`ITSAppUsesNonExemptEncryption = NO`); if it is, see `export-compliance.md`.
3. Open build 5 → **Test Details → What to Test**: paste `testflight-what-to-test.txt`.
4. **Internal Testing** → your internal group → add build 5 (internal testers get it immediately, no Beta App Review). Add external groups only if you want more hardware coverage (that requires Beta App Review).
5. Install from TestFlight on a real device and smoke-test: launch, readiness checklist, Home, Live Activity, the background-audio repro.

---

## 4. Create version 1.1 in App Store Connect
1. **Distribution** tab → iOS App → **+ Version or Platform** (the "+" next to iOS App) → enter **1.1**.
2. In the 1.1 page, **Build** section → **Add Build** → choose **1.1 (5)**.

## 5. Metadata (version page unless noted)
| Field | Source |
|---|---|
| Promotional Text | `promotional-text.txt` |
| Description | `description.txt` |
| What's New in This Version | `whats-new.txt` |
| Keywords | `keywords.txt` |
| Support URL | `urls.md` → https://orbitdeckios.n8hm.radio/documentation.html |
| Marketing URL | `urls.md` → https://orbitdeckios.n8hm.radio/ |
| Version / Copyright | `2026 Paul Stoetzer` |
| App Information → Subtitle | `subtitle.txt` (app-level; changing it is fine with a version submission) |
| App Information → Privacy Policy URL | https://orbitdeckios.n8hm.radio/privacy.html |
| App Information → Category | Primary Utilities (matches `LSApplicationCategoryType`); optional secondary Navigation or Reference |
| App Review Information → Sign-in required | **Off** (no account) |
| App Review Information → Contact | Paul Stoetzer, email n8hm@arrl.net (from `docs/privacy.html`), **phone: fill in yourself** (not in the repo) |
| App Review Information → Notes | `review-notes.txt` |
| App Review Information → Attachment | Re-attach the background-audio screen recording used for the 1.0 2.5.4 reply (shot list in `APP_REVIEW_2.5.4_BACKGROUND_AUDIO.md` §3); re-shoot it on 1.1 if the Home cards look different now |
| Version Release | See §9 |

The App Store name is app-level and not changed here; confirm what it is so the keywords don't repeat it.

## 6. Screenshots
- Folders: `Screenshots/iphone-6.9/` and `Screenshots/ipad-13/` (being regenerated by another agent; at the time of writing the iPhone folder was empty and the iPad folder held 7 images from 1.0). Wait for them to finish.
- Sizes: iPhone 6.9" **1320 × 2868** portrait; iPad 13" **2064 × 2752** portrait. Check with `sips -g pixelWidth -g pixelHeight Screenshots/iphone-6.9/*.png`. PNG or JPEG, no transparency.
- Up to 10 per device size. Apple scales the 6.9" set down to smaller iPhones and the 13" set to smaller iPads.
- Version page → **Previews and Screenshots** → iPhone 6.9" display → drag in; then iPad 13" display. Drag to order; the first three show in search results, so lead with Home, CW/packet or FT4, and the Live Activity.
- Remove any 1.0 screenshots you don't want carried over.
- Screenshots must show the app in use; device frames are optional. Don't show hardware-dependent screens claiming features you haven't verified.

## 7. App Privacy
- Follow `app-privacy.md`. Recommended label: Data Linked to You → Location (precise, coarse), Identifiers (User ID = callsign), User Content (other user content); all App Functionality; no tracking.
- The `PrivacyInfo.xcprivacy` in the build already matches these answers; keep the label and manifest in agreement.
- Publish the privacy answers (the "Publish" button on the App Privacy page) before submitting.

## 8. Export compliance and age rating
- Export compliance: `export-compliance.md` (no non-exempt encryption; nothing to answer if the plist key is present).
- Age rating: `age-rating.md`. New 1.1 capabilities (APRS messaging, DX cluster/APRS-IS/telnet content) change the Messaging and Chat and User-Generated Content answers; owner decision documented there.

## 9. Release option
Recommended: **Automatically release this version** after approval **with Phased Release for Automatic Updates** on (7-day rollout: 1%, 2%, 5%, 10%, 20%, 50%, 100%). 1.1 touches transmit and logging code that can't be fully exercised without hardware, and phased release lets you **Pause** for up to 30 days if a regression shows up while new downloads and manual updates still get 1.1. If you want to coordinate with the website announcement, choose **Manually release this version** instead and keep phased release on.

## 10. Submit for Review
1. Check every section on the version page shows no warnings (build attached, screenshots for both sizes, What's New, review contact with phone).
2. **Add for Review** → **Submit to App Review** (choose the default content rights answer: the app doesn't contain or access third-party content it lacks rights to; data feeds are public/licensed and credited in Acknowledgments).
3. Status goes Waiting for Review → In Review → Pending Developer Release / Ready for Distribution. Typical turnaround is 24–48 h.

## 11. If it's rejected
Read the message in **App Review → Messages** (Resolution Center). Reply there; don't resubmit blindly. You can reply and ask for clarification without a new build. Likely areas:

| Guideline | Risk | Response |
|---|---|---|
| **2.5.4** background audio | Highest; 1.0 was rejected once (`APP_REVIEW_2.5.4_BACKGROUND_AUDIO.md`). The new `fetch` mode is also new in 1.1. | Point to the review notes' built-in-mic repro (Settings → Audio features → Always), attach the screen recording, explain the pass duration. `fetch` is only for BGAppRefreshTask updating the Live Activity. Never cite CAT/rotator sockets as a reason for `audio`. |
| **2.1** app completeness / hardware | Reviewer can't test CAT, rotator, transmit, TNCs, servers | Hardware-free paths are in the notes; offer a video of the hardware features on air; state they require amateur equipment and a license. |
| **5.1.1** data collection / permissions | Microphone, Bluetooth, local network, location, calendar, photos | Every purpose string is specific (pbxproj INFOPLIST_KEY_*); permissions are requested only when a feature is used. Location is optional (grid or coordinates can be typed). If asked about the local-network prompt, explain it appears only when a LAN device or server is configured. |
| **5.1.2 / privacy label** | Label not matching the satgate, APRS-IS, AMSAT, hams.at, PSKReporter flows | Align the label and manifest per `app-privacy.md`; privacy.html already documents each flow. |
| **1.2** user-generated content | If the age-rating answers mark UGC/messaging | See `age-rating.md` for the reply (amateur radio traffic, filters, block lists, features can be hidden). |
| **2.3** metadata | Mentions of other apps or unverified claims | The text here names no other apps and no certifications; protocols (Hamlib rigctld) and radio models are functional descriptions. |
| **4.2** minimum functionality | Not a concern | Substantial native app. |

Fix in a new build (increment the build number to 6, keep 1.1), upload, attach it to the same version, and resubmit; or, for a metadata-only issue, edit the metadata and reply.
