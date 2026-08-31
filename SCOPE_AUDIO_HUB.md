# Scope — Shared Audio Capture Hub

Status: **planning** · Target: a future 0.9.x · Grounds three requests: pass recording
coexisting with a decoder (#5‑coexistence), a live‑listen monitor while a feature is active
(#4), and re‑establishing network audio after a CAT reconnect (#1).

## 1. Problem

Today every audio feature opens its **own** capture:

- `FT4Engine.start(source:)`, `SSTVDecoder.start(source:)`, and `PassRecorder.start(source:)`
  each call `AudioHub.makeSource()` → a **new** `USBAudioSource` (its own `AVAudioEngine`)
  or a **new** `IcomAudioSource` bound to the current `IcomNetworkTransport`.

Consequences:

- **No coexistence.** Two `USBAudioSource`s = two engines on one `AVAudioSession`; they
  conflict. 0.9.14 (8) makes input capture *exclusive* (`AudioActivity.claimCapture`) as an
  interim safety, so recording can't run with FT4/SSTV.
- **No monitor.** There's no path to also hear the received audio on the phone while a
  feature consumes it.
- **No reconnect re‑bind.** `IcomAudioSource` holds one `IcomNetworkTransport`; when
  `RigController` auto‑reconnects it builds a *new* transport, so the audio source is left
  pointing at the dead one (documented in [[cat-disconnect-reconnect]]).

## 2. Goal

One capture, many consumers. `AudioHub` owns a single active `AudioSource` and fans the
mono Float frames to any number of **subscribers** (recorder, one decoder, a live monitor),
re‑establishing the source across route changes / reconnects without dropping subscribers.

## 3. Proposed design

### 3a. A capture owned by AudioHub
- `AudioHub` gains `startCapture()` / `stopCapture()` and owns the single `AudioSource`.
- Subscribers register a frame handler: `addSubscriber(id:) -> (…)->Void` /
  `removeSubscriber(id:)`. AudioHub starts the source on the first subscriber and stops it
  on the last.
- Frames arrive on the audio thread; AudioHub calls each subscriber's handler there.
  Subscribers must stay non‑blocking (hop to their own queue for heavy work — FT4/SSTV
  already do).

### 3b. Consumers become subscribers
- `FT4Engine`/`SSTVDecoder`/`PassRecorder` stop calling `source.start` and instead
  `hub.addSubscriber`. Their `stop()` removes the subscriber. Input gain moves to the hub
  (one shared capture gain) with optional per‑subscriber gain (see §5).
- Keep the **one‑decoder rule** (FT4 XOR SSTV) from 0.9.14 (8); recorder + one decoder +
  monitor may coexist.

### 3c. Live‑listen monitor (#4)
- A new subscriber that plays frames to the **phone output** via a dedicated
  `AVAudioPlayerNode`/output source node, with its own volume + mute.
- A small "Monitor" panel (Home or a control on the audio cards) toggles it and sets level;
  appears when a USB interface or network transport is active.
- **Routing is the hard part** — see Risks §6.3.

### 3d. Reconnect re‑bind (#1)
- For the network path, AudioHub observes `RigController` (it already holds a `rig` ref) and,
  on reconnect, swaps the underlying `IcomNetworkTransport` on the live `IcomAudioSource`
  (or rebuilds the source) and re‑opens the RS‑BA1 audio stream — subscribers keep their
  registrations and see a brief gap, not a stop.
- USB path already self‑heals via the interruption/route handlers in `USBAudioSource`.

## 4. Files touched
- `Audio/AudioHub.swift` — owns capture, subscriber registry, reconnect observer, monitor.
- `Audio/AudioSource.swift` — possibly a `MultiSink` wrapper, or leave the protocol and let
  AudioHub multiplex.
- `Audio/USBAudioSource.swift` / `IcomAudioSource.swift` — support a swappable transport
  (network) and a monitor output tap.
- `DigitalModes/FT4Engine.swift`, `DigitalModes/SSTV/SSTVDecoder.swift`,
  `Recording/PassRecorder.swift` — subscribe instead of own; gain via hub.
- Views: `RecordingViews`, `SSTVViews`, `FT4Views`, plus a new Monitor control.

## 5. Gain model
Each feature currently persists its own `inputGain` (`AudioGainStore`). With one capture
there is one input gain. Plan: a single shared **capture gain** (persisted) that the level
controls all bind to, plus a per‑subscriber post‑gain only where it matters (FT4 TX output
gain stays on the TX path; the monitor has its own volume). Migrate the three input‑gain
keys to one `orbitdeck.capture.inputGain`.

## 6. Risks

1. **Real‑time fan‑out.** Frames deliver on the audio render thread; any blocking work in a
   subscriber (disk write, decode, main‑actor hop done wrong) causes dropouts. FT4 is on‑air,
   so a regression is costly. Mitigation: subscribers only enqueue on the audio thread.
2. **Single‑owner refactor.** Moving all three proven features off their own source touches
   every start/stop/gain/error path at once — broad regression surface. Mitigation: keep the
   `AudioSource` protocol; make the hub a thin multiplexer so each consumer changes minimally.
3. **Monitor output routing (highest risk).** With a USB interface, `.playAndRecord` sends
   *output* to the USB device (where FT4 TX audio goes). Getting RX monitor audio to the
   **phone speaker** while TX still goes to USB may require overriding the output port or a
   separate output node, and risks feedback or TX bleeding to the speaker. The network path
   is far easier (just play received PCM). Mitigation: ship the network‑path monitor first;
   gate the USB‑path monitor behind testing.
4. **Gain migration.** Changing three persisted keys to one is a one‑time migration; get it
   right so users don't lose their levels.
5. **Reconnect races.** Swapping the transport mid‑session races with the CAT reconnect
   sequence; must sequence "CAT reconnected" → "re‑open audio" without double‑starting.
6. **Device‑only validation.** None of this is visible to the headless build — needs a phone
   + USB interface + radio, and the still‑unproven RS‑BA1 audio path.
7. **Background/interruption.** The `USBAudioSource` interruption/media‑reset restart must
   now restart the shared capture and re‑notify all subscribers.

## 7. Phasing (lowest‑risk order)
- **P0** — AudioHub owns one capture + subscriber registry; port the three consumers behind
  the existing protocol. Keep FT4 XOR SSTV; allow recorder + decoder to coexist. (Unblocks
  #5‑coexistence.)
- **P1** — Live monitor on the **network** path only (safe output). (#4, partial)
- **P2** — Reconnect re‑bind for network audio. (#1)
- **P3** — USB‑path monitor with careful output routing. (#4, full) — behind on‑device testing.
- **P4** — Gain‑key migration + UI consolidation.

## 8. Test matrix
| Scenario | Path | Expect |
|---|---|---|
| Record + FT4 together | USB | both run; one capture; no dropouts |
| Record + SSTV together | USB | both run |
| FT4 while SSTV running | — | refused with error (one‑decoder rule) |
| Monitor while recording | network | hear RX audio; recording unaffected |
| Monitor while FT4 | network | hear RX; no TX bleed |
| CAT drop mid‑record | network | audio re‑establishes on reconnect |
| Phone call mid‑session | USB | capture + subscribers resume |

---
*Cross‑references:* `Audio/AudioHub.swift`, `Audio/AudioSource.swift`,
`Audio/USBAudioSource.swift`, `Audio/IcomAudioSource.swift`; memories
[[cat-disconnect-reconnect]], [[rsba1-audio-audit]].
