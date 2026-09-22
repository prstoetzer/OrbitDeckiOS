# Guideline 2.5.4 — Background Audio (Submission fbbf68dd-e6dc-4ee6-ba70-086958f09d96)

Rejected 2026-09-16, v1.0 (17), reviewed on iPad Air 11-inch (M3).
Resolution: keep the `audio` background mode, fix the misleading in-app copy, reply
with a screen recording, and give the reviewer hardware-free repro steps.

---

## Root cause

Two things hid the feature from the reviewer:

1. **The pass-recording card told them it doesn't work in the background.**
   `Recording/RecordingViews.swift:39` read *"Works only in the foreground."* — stale
   copy predating the background-audio support. The SSTV card at
   `DigitalModes/SSTV/SSTVViews.swift:71` already said the opposite and correct thing.
   Fixed; see §5.
2. **The audio cards are hidden by default when no interface is attached.**
   `FeatureVisibility.auto` (the default) only shows the Pass recording / SSTV / FT4 /
   Remote audio cards when an audio input is present (`AudioHub.swift:51-53`). On a bare
   review iPad all four are invisible, so there was nothing to find.

The good news: `FeatureVisibility.always` shows the cards without an interface and falls
back to the built-in mic (`RecordingViews.swift:48`, `makeSource(allowMicFallback:)`), so
the reviewer can verify background audio with **no amateur-radio hardware at all**.

## 1. Reply to send in App Store Connect

> Thank you for the review. OrbitDeck does have features that require persistent audio.
> I've attached a screen recording of them running in the background on a physical
> device, and below are steps to reproduce it on the review device with no additional
> hardware.
>
> OrbitDeck is an amateur-radio satellite operating app. A satellite pass lasts roughly
> 8–15 minutes, and the operator routinely locks the screen or switches to another app
> partway through one. Three features must keep processing audio for the full pass:
>
> 1. **Pass recording** — records the radio's received audio to an AAC file for the
>    whole pass, so the operator can review weak signals afterwards.
> 2. **SSTV and FT4 decoding** — continuously demodulate the received audio to recover
>    slow-scan television images and FT4 digital-mode messages. FT4 also synthesizes and
>    plays transmit audio out to the radio on a 7.5-second cadence.
> 3. **Remote voice** — streams the radio's received SSB audio to the device speaker so
>    the operator can listen to the satellite.
>
> Interrupting any of these doesn't merely pause playback, it loses the pass — the
> satellite has dropped below the horizon and won't return for about 90 minutes.
>
> **Why it wasn't discoverable:** these features take their audio from a connected radio
> rather than from the device, via a USB-C audio interface or over Wi-Fi from a
> network-capable transceiver. By default the app hides the audio controls when no audio
> input is attached, so on a review device with nothing connected they were not visible.
> That was our mistake in making the feature discoverable, and one of the cards also
> carried an out-of-date caption saying recording was foreground-only. We've corrected
> that caption in this build.
>
> **To reproduce background audio on the review device, no radio required:**
>
> 1. Open **Settings** (gear icon) → **Audio features** → set **Pass recording** to
>    **Always**. This reveals the control without an interface attached and records from
>    the built-in microphone instead.
> 2. Go to the **Home** screen. Select any satellite if one isn't already selected. The
>    **Pass recording** card now appears near the bottom of the screen.
> 3. Tap **Record**, and allow microphone access. The timer starts counting.
> 4. Press the Home gesture to go to the **Home Screen**, or lock the device. The orange
>    audio indicator appears in the status bar and recording continues.
> 5. Wait 30 seconds, reopen OrbitDeck, and note the timer has advanced past the point
>    where you left. Tap **Stop**, then open **Log → Pass recordings** to play back the
>    audio that was captured while the app was in the background.
>
> The same works for **SSTV decode** set to **Always** — the image continues building
> while backgrounded.
>
> I've added this explanation and the recording to the App Review Information notes for
> future submissions. Happy to answer any further questions.

## 2. App Review Information → Notes (permanent, for every future submission)

> OrbitDeck is an amateur-radio satellite tracking and operating app.
>
> BACKGROUND AUDIO (UIBackgroundModes: audio): a satellite pass lasts 8–15 minutes and
> the operator commonly locks the screen mid-pass. The app must keep recording and
> playing audio throughout: (1) Pass Recording captures the radio's received audio to an
> AAC file; (2) SSTV and FT4 continuously decode received audio, and FT4 also plays
> synthesized transmit audio out to the radio; (3) Remote Voice streams the radio's
> received audio to the device speaker. A screen recording demonstrating this on a
> physical device is attached.
>
> TO VERIFY WITHOUT RADIO HARDWARE: Settings → Audio features → Pass recording →
> "Always". This reveals the Pass recording card on the Home screen and records from the
> built-in mic. Tap Record, background the app or lock the screen, wait, return — the
> timer has advanced, and the file plays back under Log → Pass recordings.
>
> HARDWARE NOTE: in the default "Auto" setting the audio cards are hidden unless an audio
> input is attached, because they are designed to take audio from a transceiver via a
> USB-C audio interface or a network-capable radio on the same Wi-Fi. Rig control (CAT)
> and rotator control additionally need a Bluetooth LE serial adapter or a network
> rotator; those two are deliberately foreground-only and do not use the audio
> background mode. All satellite tracking, pass prediction, mapping, and logging works
> with no hardware attached and can be reviewed normally.
>
> No account or login is required. No user data leaves the device except optional,
> user-initiated log uploads to Cloudlog/LoTW with credentials the user supplies.

## 3. Screen recording shot list (~60–75 s, physical device)

Use iOS Screen Recording on a physical iPhone (not the simulator). Shoot it with the USB
audio interface connected to a radio if convenient, but the built-in-mic path via
"Always" is equally valid and easier to film.

1. (0:00) Home screen, audio interface connected — briefly show the input level meter
   moving so it's clear real audio is arriving.
2. (0:10) Tap **Record** on the Pass recording card. Show the timer counting and the
   level meter active.
3. (0:20) **Swipe up to the Home Screen** and hold there. Capture:
   - the orange audio-in-use indicator in the status bar;
   - at least 25–30 seconds of wall clock, so the elapsed time is unambiguous.
4. (0:50) Reopen OrbitDeck. Show the timer has continued past where you left — the single
   most important frame in the video.
5. (1:00) Tap **Stop**, open the saved recording, and play it back so the reviewer hears
   audio captured while the app was backgrounded.

Optional if quick: repeat 3–4 with SSTV decoding active, showing image lines that
advanced while backgrounded.

**Do not** narrate the CAT/rotator link staying connected as a reason for the background
mode — keeping BLE/network sockets alive is not a valid use of `audio` and raising it
invites a second rejection. The app's own CAT and rotator cards correctly state those are
foreground-only; that's worth leaving visible.

**Do not** demo Remote Voice: the RS-BA1 network audio path is still marked EXPERIMENTAL
and is not hardware-validated (`Audio/AudioHub.swift:463`).

## 4. Consider before resubmitting

The `auto` default is what made the feature undiscoverable, and it will do the same to
every future reviewer. Worth considering for a follow-up build: show the audio cards in a
disabled state with an explanatory line ("Connect a USB audio interface, or set Pass
recording to Always in Settings to use the built-in mic") rather than hiding them
outright. Not required to clear this rejection.

## 5. Code changes made

- `OrbitDeckIOS/Info.plist` — rewrote the `UIBackgroundModes` comment to justify the mode
  purely on audio capture/playback for the duration of a pass. The old comment cited "the
  CAT/network link that rides alongside it," which is not a legitimate use of the `audio`
  mode. The key value is unchanged.
- `Recording/RecordingViews.swift:39` — replaced "Works only in the foreground." with
  "Keeps recording with the screen locked or the app backgrounded during a pass.",
  matching the SSTV card's wording and the app's actual behavior.
