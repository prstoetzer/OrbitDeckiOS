# TestFlight — OrbitDeck 0.9.14 (9) · What to Test

This build introduces a shared audio engine so pass recording can run alongside a
decoder, and adds **remote SSB voice** — listen to your Icom network radio and talk
through the phone. Please exercise the audio features, especially with an IC-9700/705 over
the network.

## Headline changes
- **Shared audio capture.** FT4/SSTV/recording now share one audio engine, so **pass
  recording can run at the same time as FT4 or SSTV**. FT4 and SSTV remain mutually
  exclusive (only one decoder at a time), with a clear message if you try to start a second.
- **Remote audio (voice) — NEW.** On an Icom **network (RS-BA1)** radio, a new Home card
  lets you **listen to the radio on the phone and hold-to-talk** for an SSB or FM voice QSO,
  with PTT keyed over CAT.

> Experimental: remote voice rides the RS-BA1 network-audio path, which isn't yet
> hardware-validated. Feedback from real on-air use is exactly what's needed.

## What to test

### 1. Recording + decoder coexistence
- Start **Pass recording**, then start **FT4** (or **SSTV**). **Good:** both run at once; the
  recording keeps going and the decoder decodes. Stop either independently.
- Start **FT4**, then try **SSTV** (or vice versa). **Good:** the second is refused with
  "Audio is in use by … Stop it first." Stop the first, then the other starts.

### 2. Remote SSB voice (Icom network radio)
- Connect an **IC-9700 / IC-705** over the network (see the IC-9700 network FT4 guide for
  radio setup; the same network/audio settings apply).
- On the new **Remote audio (voice)** Home card, tap **Listen** — you should hear the
  radio's receive audio on the phone (**use earphones** to avoid feedback).
- **Hold TRANSMIT** to talk: the button turns "ON AIR," PTT keys the radio, and your mic
  audio is sent. Release to stop. Confirm you can complete an SSB or FM voice QSO.
- Confirm PTT keys/unkeys cleanly and never sticks on release or when you tap **Stop**.

### 3. Regression — FT4 / SSTV / recording still work solo
- Run each on its own (USB interface or network) exactly as before. **Good:** no change in
  behavior — FT4 decodes/transmits, SSTV decodes, recording saves a clip.
- Audio input/output levels still work (they now drive one shared capture gain).

## Please report
- Recording + decoder not coexisting, or audio dropouts when both run.
- Remote voice: no RX audio, mic not transmitting, PTT sticking, or bad echo/feedback.
- Any regression in solo FT4 / SSTV / recording.
- Which radio + connection (USB or network) you used.

## Diagnostics
Log categories: `cat` (connect/drop/reconnect, `setPTT`), `audio`, `ft4` (`FT4 TX dT=…`).

## Notes & limits
- Remote voice is **network-path only.** iOS captures only one audio input at a time, and
  with a USB interface that input is the radio's receive audio — so the phone mic isn't
  available to transmit (FT4 works over USB because its TX audio is generated in software,
  not from the mic). If both USB and a network radio are connected, the shared capture
  prefers USB — use the network radio alone for remote voice.
- A USB-interface live monitor (hearing USB audio on the phone speaker) is not included: on
  a bidirectional interface that output would feed back into the radio.
- Half-duplex single-radio FT4 is still planned (`SCOPE_HALFDUPLEX_FT4.md`).
