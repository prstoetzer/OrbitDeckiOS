# Age rating — OrbitDeck 1.1

App Store Connect → the app → **App Information → Age Rating → Edit**. The questionnaire is per app (not per version), so it may still hold the 1.0 answers; 1.1 adds features that change two capability answers (below), so review it before submitting.

## Content questions (all "None" / "No")

| Section | Question | Answer | Reasoning |
|---|---|---|---|
| Mature themes | Profanity or crude humor | None | No such content authored by the app. |
| | Horror/fear themes | None | |
| | Alcohol, tobacco or drug use or references | None | |
| Medical or wellness | Medical or treatment information | None | |
| | Health or wellness topics | None | |
| Sexuality or nudity | Mature or suggestive themes / sexual content / nudity / graphic sexual content | None | |
| Violence | Cartoon or fantasy / realistic / prolonged graphic or sadistic / guns or other weapons | None | |
| Chance-based activities | Simulated gambling / gambling / contests / loot boxes | None / No | Awards (VUCC, WAS, DXCC) are a personal log tally, not a contest run by the app; no prizes, no purchases. |

## Features and capabilities

| Question | Answer | Reasoning |
|---|---|---|
| Parental controls | No | None in the app. |
| Age assurance | No | No age checks. |
| Advertising | No | No ads (privacy policy). |
| Unrestricted web access | **No** | No in-app browser: no `WKWebView`, `SFSafariViewController` or WebKit import (grepped). Links open in Safari. The Telnet console is a plain terminal to a host the user types, not a web browser. |
| Messaging and chat | **Yes (recommended)** | New in 1.1: Packet / APRS lets the user send and receive free-text APRS messages and bulletins with other amateur stations through satellites and the ISS (with alerts and optional spoken readout). That is person-to-person messaging, even though it travels by radio. |
| User-generated content | **Yes (recommended), owner decision** | New in 1.1: the app displays content created by other people that it doesn't moderate: APRS messages, bulletins, status text and objects (radio and APRS-IS), DX cluster spots and announcements, telnet sessions, and received SSTV images. |

### Owner decision: messaging and UGC

- Answering **Yes** is the accurate answer and avoids a metadata-mismatch rejection later. App Store Connect computes the rating from the whole questionnaire and shows it on the summary before you save; read the result there rather than assuming 4+. If the computed age changes from 1.0's rating, that is expected for these capabilities.
- Answering Yes can draw **Guideline 1.2 (user-generated content)** questions about filtering, reporting and blocking. If asked, reply that: the content is amateur-radio traffic between licensed operators, governed by their license rules (in the US, FCC Part 97 prohibits obscene or indecent transmissions); OrbitDeck runs no server and hosts nothing; the user can filter the packet monitor by callsign or text and hide beacons/status, keep a watch list, use a CQ block list in FT4, and turn each feature off (Settings → Audio features → Hidden; Nearby & DX connects only while open). Report-to-developer and block-user tooling don't exist; if App Review insists, that would be a code change.
- A defensible alternative is "No" for user-generated content, on the basis that the app is a radio receiver displaying over-the-air transmissions rather than a platform for users to post content. It is less conservative; pick it only if you are comfortable explaining it.

## Other settings on the same page

- **Made for Kids**: No.
- **Age rating override** (raise the rating manually): not needed.
- The privacy policy already states the app is not directed to children.
