# TestFlight — OrbitDeck 0.9.14 (7) · What to Test

This build hardens the radio/audio subsystems: connections and audio now survive leaving
the home screen, backgrounding, and interruptions, and a network-radio disconnect bug is
fixed. It also persists your audio setup. Please exercise CAT, the rotator, and the audio
modes (recording / SSTV / FT4), especially with an Icom network radio.

## Headline changes
- **IC-9700 / IC-705 (network) disconnect fixed.** A dropped RS-BA1 socket is now torn down
  cleanly (frees the radio's session) and auto-reconnects — no more silent dead connection
  or "a session is already open" on reconnect. PTT is logged for diagnosis.
- **Everything keeps running off the home screen.** CAT, rotator, recording, SSTV and FT4
  continue while you move around the app.
- **Survives backgrounding & interruptions.** Audio modes keep running with the screen
  locked / app backgrounded during a pass; connections re-establish when you return.
- **Audio setup is saved.** Input/output gain for recording, SSTV and FT4 persists across
  launches. SSTV now has an always-available input-level control.

## What to test

### 1. Runs everywhere in the app (not just Home)
- Start FT4 (or SSTV, recording, CAT, rotator) from the Home card, then navigate to other
  tabs/screens and back. **Good:** it's still running/connected when you return.

### 2. Leave the app and come back (re-establish state)
- With CAT connected (and/or rotator, and/or an audio mode running), **background the app**
  (or lock the screen) for 30–60 s, then reopen.
  - **Audio modes (recording/SSTV/FT4):** should keep running in the background during a
    pass and still be going when you return.
  - **CAT / rotator:** if the link dropped while away, it should reconnect automatically on
    return (watch the Home card status).
- **Phone-call test:** while decoding/recording, take a phone call, then hang up — audio
  should resume on its own.
- Known limit: **CAT-only** (Doppler tracking with no audio mode active) may still suspend
  in the background — reopening reconnects it. Please report if it doesn't.

### 3. IC-9700 / IC-705 over the network (the fixed bug)
- Connect over Wi-Fi (RS-BA1). Confirm **PTT keys/unkeys** for FT4 TX.
- Force a drop: briefly drop Wi-Fi, or background the app long enough for the sockets to
  die. **Good:** status shows reconnecting and it comes back; the radio does **not** complain
  about an existing session on reconnect.
- Confirm no runaway behavior after a drop (it should not keep tuning a dead connection).

### 4. Audio setup persistence
- Set input/output gain in FT4, SSTV, and Recording. Quit and relaunch. **Good:** the sliders
  are where you left them.
- SSTV: the input-level control is now in "Setup & calibration" even before you tap Decode.

### 5. Rotator reconnect
- With a networked rotator (rotctld/PstRotator) connected, drop and restore its
  server/Wi-Fi. **Good:** it reconnects and resumes pointing.

## Please report
- Any connection that goes dead silently or won't reconnect on return.
- IC-9700/705 PTT not keying, or the radio complaining about a session on reconnect.
- Audio not resuming after a call/background, or dropouts.
- Gains not persisting.

## Diagnostics
Debug log categories: `cat` (connect/drop/reconnect, `setPTT(...)`), `rotator`,
`audio` (`usb-audio: restarting capture …`), `ft4` (`FT4 TX dT=…`). Include a snippet if you
hit a connection or PTT issue.

## Not in this build
Half-duplex / single-radio FT4 (e.g. IC-705 as the only radio, alternating bands) is still
planned, not included (see `SCOPE_HALFDUPLEX_FT4.md`). RS-BA1 network audio does not yet
auto-recover across a full CAT reconnect — the USB-audio path is the robust one.
