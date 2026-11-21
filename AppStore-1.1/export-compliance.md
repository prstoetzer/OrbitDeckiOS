# Export compliance (encryption) — OrbitDeck 1.1

## Recommendation

**No non-exempt encryption.** Keep `ITSAppUsesNonExemptEncryption = NO`. App Store Connect then skips the encryption questions for build 5; no documentation or annual self-classification report is needed, and no French declaration is required.

## What the project declares

- App target (Debug and Release): `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` in `OrbitDeckIOS.xcodeproj/project.pbxproj` (set in commit ec83ca0 for 1.0 (17); unchanged).
- The widget extension (`OrbitDeckWidgets`) doesn't set it; App Store Connect reads the key from the app's Info.plist, which covers the bundle. The extension contains no cryptography of its own.
- No entitlements files exist in the repo (no `.entitlements`, no `CODE_SIGN_ENTITLEMENTS`), so there are no keychain-sharing, App Group or iCloud entitlements to consider.

## Cryptography actually used (verified in code)

| Use | Where | Implementation | Classification |
|---|---|---|---|
| HTTPS/TLS to web services (CelesTrak, AMSAT, NOAA SWPC, SatNOGS, hams.at, Open-Meteo, Space-Track, QRZ, LoTW, Cloudlog over https) | `URLSession` throughout | Apple's OS (ATS) | Exempt: encryption provided by and accessed through Apple's operating system |
| LoTW QSO signing | `OrbitDeckIOS/Log/LoTW.swift` | `SecPKCS12Import` to load the user's ARRL certificate; `SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA1)` to sign each QSO record; upload over HTTPS | Exempt twice over: it calls Apple's Security framework (OS-provided), and it is a **digital signature for authentication/data integrity**, not encryption for confidentiality. EAR Category 5 Part 2 Note 3 / the authentication and integrity exclusions in 740.17 and the 5A002 decontrol notes cover signing that doesn't encrypt the payload; the .tq8 file is gzipped plaintext plus signatures. |
| Keychain storage of passwords, API keys, the LoTW passphrase and the APRS-IS passcode | `OrbitStore.swift`, `LoTW.swift`, `Cloudlog.swift` and others (`SecItem*`) | Apple's OS (Keychain, data protection) | Exempt: OS-provided |
| LoTW `.p12` at rest | app container with iOS data protection | Apple's OS | Exempt |
| Icom network login "passcode" | `OrbitDeckIOS/CAT/IcomNetwork.swift` (`passcode()`) | A fixed substitution table the Icom RS-BA1 protocol requires for interop | Not cryptography in the EAR sense (fixed obfuscation, no key), used only for authentication to the user's own radio |
| gzip of the LoTW upload | `LoTW.swift` (`Gzip`) | Compression | Not encryption |
| Raw TCP/UDP (rigctld/rotctld, KISS TCP, APRS-IS, DX cluster, telnet, PSKReporter, rotators) | `NWConnection(..., tls: nil)` | None (plaintext by protocol design) | No encryption |

No CryptoKit, CommonCrypto, OpenSSL/BoringSSL or custom cipher code is present (grepped for `CryptoKit`, `CommonCrypto`, `CCCrypt`, `AES`, `ChaChaPoly`, `SecKeyCreateEncryptedData`, `Insecure.`, `sec_protocol`). The SatelliteKit package (SGP4) contains no cryptography.

## If App Store Connect asks anyway

If the build's Info.plist lost the key (for example after a project change) and App Store Connect shows the questionnaire under the build:

1. "Does your app use encryption?" → **Yes** (it uses HTTPS), then
2. "Does your app qualify for any of the exemptions provided in Category 5, Part 2 of the U.S. Export Administration Regulations?" / "What type of encryption algorithms does your app implement?" → choose the answer meaning **only encryption within Apple's operating system / exempt** ("None of the algorithms mentioned above" in the current wording, since the app neither implements proprietary nor standard algorithms itself).

Either path ends with no export documentation required. Prefer restoring `ITSAppUsesNonExemptEncryption = NO` in Xcode (target → Info) so future builds skip the question.
