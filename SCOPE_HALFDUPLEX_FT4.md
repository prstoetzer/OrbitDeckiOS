# Scope — Half-Duplex FT4 (single-radio, non-full-duplex rigs)

Status: **planning** · Target: a future 0.9.x · Author aid: cross-audit of `FT4Engine`,
`RigController`, `RadioCatalog`, `AudioSource`.

## 1. Goal

Let operators run satellite FT4 on radios that **cannot** transmit and receive at the
same time — the entire non-full-duplex ("mono") half of `RadioCatalog`. The reference
target is the **IC-705**, but the design must generalize to every qualifying rig.

Full-duplex FT4 (today) assumes the radio is on downlink and uplink simultaneously
(IC-9700 SAT MAIN/SUB, FT-847, two radios, etc.). A mono rig has **one VFO on one band at
a time**, so it must *alternate*: receive the downlink on RX slots, then band-change to the
uplink and transmit on TX slots, doing the turn-around inside the ~2.4 s of dead air after
each 5.04 s burst.

## 2. What already exists (reuse, don't rebuild)

- **Audio both directions.** `IcomAudioSource` implements `start` (RX) *and* `startPlayback`
  (TX) over RS-BA1 (`Audio/IcomAudioSource.swift`). `USBAudioSource` covers a USB audio
  interface. The `AudioSource` protocol cleanly separates capture from playback.
- **Per-leg Doppler dials.** `RigController.tick()` already computes `rxReal`/`txReal` with
  calibration, passband offset, transverter LO, and adaptive deadband
  (`CAT/RigController.swift:343-429`).
- **Slot-gated tuning + pre-arm.** `holdDoppler` freezes the dial per slot; `FT4Engine`'s
  pre-arm (`schedulePreArmTimer`/`preArmUpcomingSlot`) already steps the dial + keys PTT in
  the dead-air tail before a TX slot. Half-duplex is a *generalization* of this hook.
- **Per-family CAT codecs.** `CATCodec` has freq/mode/PTT encoders for CI-V, Yaesu binary,
  Yaesu FT-100, Kenwood base — reused by `setPTT` (`RigController.swift:656`) and the tuner.
- **Sideband-aware TX Doppler sign.** `FT4Engine.uplinkAudioInverted` already flips the TX
  pre-comp for inverting transponders — unchanged by duplex mode.

So this is mostly **new orchestration**, not new plumbing.

## 3. Radio capability matrix — "all non-satellite radios"

The `mono` list (`RigTypes.swift:113-163`) splits into three buckets. Half-duplex
*alternating* FT4 only applies to the first.

### 3a. Half-duplex capable — multiband + can TX  → **the target set**
Covers **both** the uplink and downlink bands and can be keyed:

| Radio | Family | Connectivity | Notes |
|---|---|---|---|
| IC-705 | CI-V | LAN (RS-BA1) or BLE serial | reference target; net audio both ways |
| IC-905 | CI-V | LAN or BLE serial | VHF/UHF/SHF; `wideFreq` |
| IC-7100 | CI-V | BLE serial | HF/50/144/430 |
| IC-7000 | CI-V | BLE serial | HF/50/144/430 |
| IC-706MKIIG | CI-V | BLE serial | has 430; MKII/706 do **not** → 3b |
| FT-817 / FT-818 | Yaesu binary | BLE serial | QRP all-band |
| FT-857 / FT-897 | Yaesu binary | BLE serial | HF/50/144/430 |
| FT-100 | Yaesu FT-100 | BLE serial | HF/50/144/430 |

### 3b. Single-band TX rigs — **cannot alternate** (one leg only)
Physically reach only one of the two bands, so they can never do both legs on one radio.
These remain **two-radio-station** legs (out of scope for v1 FT4 — see §10):
IC-275/IC-271 (2 m), IC-475/IC-471 (70 cm), IC-575 (6/10 m), IC-1275 (23 cm),
IC-706MKII/IC-706, TS-711 (2 m), TS-811 (70 cm).

### 3c. RX-only — **monitor only, no TX**
`rxOnly` in the catalog, so no half-duplex TX. They already work as downlink monitors and
stay that way: IC-R10/R20/R30/R7000/R7100/R8500/R8600/R9000/R9500, VR-5000,
TH-D74/TH-D75. (The D74/D75 HTs can physically transmit but the app models them RX-only via
the B.B. Link adapter — no data-TX path, so no change.)

### Capability gap to close
`RadioSpec` has **no band-coverage metadata**, so the app can't currently tell 3a from 3b
(e.g. IC-706MKIIG vs IC-706MKII). **Add a coverage descriptor** — minimally a
`bands: Set<Band>` or a `multiBandTX: Bool` on `RadioSpec` — and gate the half-duplex option
on `!fullDuplex && !rxOnly && coversBothLegs(transponder)`. Without this we'd either offer
half-duplex on rigs that can't reach both bands or hard-code an allow-list.

## 4. Audio-path matrix

The engine is audio-device-agnostic (`AudioSource` is independent of `RigController`), but
setup differs:

| CAT connectivity | Audio in/out | Combo |
|---|---|---|
| IC-705 / IC-905 over **LAN (RS-BA1)** | `IcomAudioSource` (net, both ways) | single connection — cleanest |
| CI-V / Yaesu over **BLE serial** | **USB audio interface** (`USBAudioSource`) to the rig's data/ACC port | two connections (CAT over BLE, audio over USB-C) |

BLE serial carries **CAT only** — there is no audio over it — so every 3a rig except the
networked Icoms needs a separate USB audio interface. The plan must make this explicit in
setup UX.

## 5. Architecture changes

### 5a. `RigController` — half-duplex alternating tuner
- **Duplex concept.** Add `enum FT4Duplex { case full, half }` (or derive from the connected
  rig's `fullDuplex`). A half-duplex session drives a single link whose role is `.both`.
- **`func tuneLeg(_ leg: RigRole) async`** — command the one VFO to that leg's
  Doppler-corrected frequency **and** mode (USB downlink / LSB uplink on an inverting bird,
  reusing `uplinkMode`). Reuses `dopplerFrequencies` + calibration + transverter offsets from
  `tick()`; sends via the existing per-family freq/mode encoders.
- **PTT interlock (safety-critical).** `setPTT(true)` must be refused/guarded unless the VFO
  is currently on the **uplink**. Track a `currentLeg` and never key while on downlink — a
  bug here means transmitting on the downlink band.
- **Idle = park on downlink.** When not in an active TX exchange, stay on downlink and receive
  every slot. Only alternate for slots actually transmitted.

### 5b. `FT4Engine` — `.half` mode
- Add `duplex: FT4Duplex`. In `.half`:
  - **Skip decoding TX slots** (no downlink audio while transmitting) — gate the
    `decodeSlot` call and the "No RX audio this slot" status accordingly.
  - **Drop self-decode expectations** (can't hear yourself half-duplex) — UI copy + the
    `isFromMe` full-duplex affordance.
  - **Alternate the audio path** instead of running capture+playback together: `stop()`
    capture → `startPlayback` for the TX slot → `stopPlayback` → restart capture. All four
    calls already exist on `AudioSource`.
  - **Two-sided pre-arm.** Extend `preArmUpcomingSlot` to fire before **both** boundary
    types: before a TX slot → `tuneLeg(.uplink)` + mode + PTT-on; before the return RX slot →
    PTT-off + `tuneLeg(.downlink)` + mode. Today it only handles the TX side.
  - **Longer / adaptive lead.** `kFT4PreArmLead` (0.5 s for full-duplex) is too tight for a
    cross-band QSY + mode + PTT. Make it per-duplex and ideally per-family (see §6): ~1.0–1.5 s
    for half-duplex, still inside the 2.4 s dead window.

### 5c. `AudioSource`
- Verify `IcomAudioSource`/`USBAudioSource` tolerate **repeated capture start/stop each slot**
  without dropouts or costly session renegotiation. Likely fine (keep the stream/engine up;
  gate delivery), but must be measured; may warrant a "pause/resume capture" that keeps the
  engine running rather than full stop/start.

### 5d. UI / config
- **Capability-gated toggle** in the FT4 setup card: offer "Half-duplex (single radio)" only
  when §3's gate passes; otherwise explain why (single-band, RX-only, or already full-duplex).
- **Setup guidance** per §4 (net-audio vs USB-audio-interface).
- **Slot clock** already shows TX/RX (`FT4Views.swift:190`); add a **QSY/turn-around** state
  and a "can't hear during TX" note. No self-decode indicator.

## 6. Timing budget (the primary risk)

Turn-around after a TX slot: burst ends ~5.04 s in; the next downlink signal starts ~0.5 s
into the next slot → roughly **2.9 s** to unkey, band-change QSY, set mode, and be receiving.
Comfortable *only if* the CAT link is quick:

- **Networked Icom (IC-705/905 LAN):** fast; 0.5–1.0 s lead likely enough.
- **CI-V over BLE serial (19200):** moderate.
- **Yaesu binary over BLE serial (9600/4800):** slowest — a freq+mode+PTT sequence could be
  several hundred ms. Needs the longest lead and must be validated first.

**Action:** make the pre-arm lead per-family and instrument both ends — the existing
`FT4 TX dT` log plus a new symmetric **"RX ready" timestamp** — to prove each family turns
around in time on a dummy load before going on air.

## 7. Doppler correctness (mostly free)

- RX audio de-Doppler and TX audio pre-comp are per-slot and **unchanged** — they already
  assume a dial held for the slot, which is exactly what half-duplex does per leg.
- The sideband sign fix (`uplinkAudioInverted`) applies identically.
- Coarse dial: single VFO stepped to the active leg's corrected frequency each boundary via
  `tuneLeg`. Reuses all existing correction math.

## 8. Hard parts / risks

1. **Per-family QSY+mode+PTT timing** within the turn-around window (esp. Yaesu-binary over
   BLE). Go/no-go gate.
2. **PTT-on-downlink interlock** — safety; must be impossible to key on the wrong band.
3. **Audio start/stop churn** each slot without glitches.
4. **Band-coverage metadata** — new `RadioSpec` field + a correct 3a/3b/3c classification.
5. **USB-audio + BLE-CAT dual-connection UX** for non-networked rigs.

## 9. Phasing

- **Phase 0 — Spike (go/no-go).** Bench-only: for one CI-V rig and one Yaesu-binary rig,
  measure cross-band QSY + mode + PTT turn-around vs the 2.9 s budget on a dummy load. Decide
  per-family leads. No engine changes yet.
- **Phase 1 — CAT.** `FT4Duplex`, `tuneLeg`, PTT interlock, `currentLeg`, per-family lead.
- **Phase 2 — Engine.** `.half` mode: RX-only-slot decode, alternating audio path, two-sided
  pre-arm, no-self-decode.
- **Phase 3 — Capability + UI.** `RadioSpec` band coverage, gated toggle, setup guidance,
  slot-clock QSY state.
- **Phase 4 — On-air validation** on an inverting linear bird, per §11 matrix.

## 10. Out of scope (v1)

- **Two-radio FT4** (a 3b single-band rig per leg): needs simultaneous RX audio from one
  device and TX audio to another — the engine currently binds one `AudioSource`. Separate
  effort (dual audio routing).
- **RX-only rigs** for TX (§3c): unchanged; monitor only.
- **VOX-only stations without CAT PTT:** half-duplex needs deterministic PTT + band change;
  CAT PTT (`pttSupported`) should be required.

## 11. Test matrix

| Radio | CAT | Audio | Validate |
|---|---|---|---|
| IC-705 | LAN | RS-BA1 net | turn-around, self-QSO on inverting bird, no-drift |
| IC-705 | BLE serial | USB audio i/f | dual-connection setup, timing |
| IC-9700 (regression) | LAN | net | full-duplex path unchanged |
| IC-7100/7000 | BLE serial | USB audio i/f | CI-V band QSY timing |
| FT-817/818 | BLE serial | USB audio i/f | slowest QSY; lead tuning |
| Single-band (IC-275) | — | — | correctly **not** offered half-duplex |
| RX-only (TH-D75) | — | — | remains monitor; no TX offered |

---

*Cross-references:* `FT4Engine.swift` (slot loop, pre-arm, `beginTransmit`),
`RigController.swift:343` (`tick`), `:656` (`setPTT`), `:675` (`uplinkMode`),
`RigTypes.swift:113` (`mono` catalog), `AudioSource.swift`. See also memory
`ft4-doppler-timing`, `cat-cardsat-orchestration`.
