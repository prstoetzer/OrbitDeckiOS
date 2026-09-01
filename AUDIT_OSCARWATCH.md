# Audit — OrbitDeck vs OscarWatch‑Tracker (CAT & rotator parity + defects)

Status: **audit / planning input for the next build** (no code changes). Read‑only
comparison of OrbitDeck (`OrbitDeckIOS/`) against OscarWatch‑Tracker
(`/tmp/OscarWatch-Tracker`, C#/.NET). OscarWatch is a mature desktop pass‑tracker with
strong rig/rotator automation; this maps where OrbitDeck lags, where it leads, and the
CAT/rotator defects & improvements worth doing.

Confidence tags: **[gap]** confirmed missing in OrbitDeck · **[verify]** likely issue,
confirm in OrbitDeck code first · **[improve]** works but OscarWatch does it better ·
**[lead]** OrbitDeck ahead.

---

## 1. Radio (CAT) parity

| Family | OscarWatch | OrbitDeck | Notes |
|---|---|---|---|
| Icom CI‑V | 910/9100/9700/821H/905/705/7300/706 | 820/821/910/970/9100/9700/705/905/7100/7000/706×3/2xx/4xx + RX‑only R‑series | OrbitDeck covers **more** Icoms |
| Yaesu | FT‑847, 817/818, 991/991A/FTX‑1 | FT‑847, 736R, 817/818/857/897, FT‑100, VR‑5000 | OrbitDeck adds 736R/857/897; OscarWatch adds 991 (USB‑only → unreachable on iOS anyway) |
| Kenwood | TS‑2000, TH‑D74/75 | TS‑790, TS‑2000, TS‑711/811, TH‑D74/75 | Comparable |
| **FlexRadio SmartSDR** | **FLEX‑6400/6500/6600/6700/8000** (slices, dual‑pan, antenna routing, full‑duplex) | **none** | **[gap] Biggest CAT parity gap.** Flex is TCP/IP — reachable on iOS |
| Hamlib rigctld | rigctl TCP (downlink‑only) | rigctld (full split + PTT + data) | OrbitDeck **[lead]** (bidirectional) |

**OrbitDeck [lead] overall:** BLE‑serial + Icom RS‑BA1 network CAT **and audio**, more Icom
models, bidirectional rigctld, plus SSTV/FT4/remote‑voice/pass‑recording/LoTW that OscarWatch
lacks. The one clear radio gap is **FlexRadio**.

---

## 2. CAT defects & improvements (prioritized)

1. **[gap — CONFIRMED] Narrow‑FM (FM‑N) filter not selectable.** OscarWatch sends the FM‑N
   filter byte per‑rig — IC‑910 `06 05 02` (narrow) vs `06 05 01` (wide); plain `06 05` leaves
   wide FM (`IcomCivCodec.cs:121–133`). Verified in OrbitDeck: `RigMode` (`RigTypes.swift:19`)
   is `lsb, usb, cw, fm, am, data` — **no `.fmn`**; `RigMode.parse` maps any "FM"/"FMN"/"FM‑N"
   → `.fm` (`RigTypes.swift:29–39`); `CATCodec.civSetMode` FM path emits `06 05 01` (filter
   hardcoded to 0x01=wide) or `06 05` when `modeFilter=false` (`CATCodec.swift:48–52`) — **no
   path ever emits 0x02 (narrow)**. So OrbitDeck cannot command narrow FM on any rig. Most V/U
   **FM satellites** (SO‑50 etc.) want NFM. **Highest‑value fix:** add an FM‑N mode + filter‑02
   path (start with IC‑910/9100/9700), driven from the transponder mode string.
2. **[gap — CONFIRMED] TS‑2000 / TS‑790 never enter satellite mode.** Both specs are
   `fullDuplex:true, hasSatMode:true` but `satModeCmd:0, satModeSub:0`
   (`RigTypes.swift:100–107`), and `engageOnce` only sends a sat‑mode command for **CI‑V**
   rigs (`RigController.swift:333–341`) — Kenwood (`.kenwoodBase`) gets none. Tuning is just
   `FA`(VFO‑A=downlink)/`FB`(VFO‑B=uplink) freq + `MD` mode (`CATCodec.swift:255–258`,
   `RigController.swift:593–598, 665–668`); **no SATL entry handshake** (nothing like
   OscarWatch's `DC00 → FR → DC11 → SA… → TS1 → AI2 → MD…`, `KenwoodCatCodec.cs:38–113`). The
   rig is driven as a generic dual‑VFO radio, not put into formal satellite/split mode — likely
   to mistrack (or fail split) on hardware. **Fix:** implement the Kenwood SATL entry/exit
   sequence and Main/Sub TX‑control swap. (Untested on hardware — validate with a TS‑2000 user.)
3. **[improve] Doppler predictive lead near/after TCA.** OscarWatch's `DopplerCatLead` adds
   slope‑blended lead with **residual‑leg** (post‑TCA, +25 Hz‑ish) and **receding‑leg**
   assists (up to 75 ms, 40% floor near LOS), plus a configurable lead gain
   (`DopplerCatLead.cs:145–228`). OrbitDeck has a TCA lead **taper** + adaptive deadband
   (`RigController.swift:481–529`) but no post‑TCA receding assist. Adopting the receding‑leg
   lead would tighten tracking on the outbound half of fast UHF passes.
4. **[improve] Interactive dial "settle/resume" model.** OscarWatch pauses CAT while the
   operator tunes and resumes after an 800 ms settle (2500 ms for the uplink/Sub), with
   per‑mode capture thresholds (30 Hz linear / 250 Hz FM) (`InteractiveDialResumePolicy.cs`,
   `KnobTuneCapturePolicy.cs`). OrbitDeck's "One True Rule" folds dial moves into the passband
   offset continuously (`RigController.swift:466–479`) — simpler, but can fight the operator
   or jitter. A settle window could feel smoother; evaluate against current behavior.
5. **[improve] Follow‑dial band‑plausibility guard.** OscarWatch guards against misreading
   the uplink band as the downlink on cross‑band rigs (`RigFrequencyBands.cs`). OrbitDeck's
   follow only guards `abs(delta) < 1 MHz` — add a band/region sanity check before folding a
   read into the offset.
6. **[gap] CW‑through‑linear uplink toggle.** OscarWatch can switch the uplink to CW while
   keeping (or also switching) the downlink, for CW QSOs through a linear transponder
   (`TransponderOperatingModes.SupportsCwUplinkToggle`). OrbitDeck has no CW‑uplink operating
   toggle. Nice parity feature for linear‑bird CW ops.
7. **[gap, minor] Separate RX offset for Voice vs CW** on linear SSB (OscarWatch stores both;
   OrbitDeck has a single passband offset).

**Verified OK (NOT a defect):** Same‑band simplex (e.g. ISS packet 145.825, uplink==downlink)
is handled correctly — the loop still Doppler‑corrects and commands **both** legs; there's no
`up==down` short‑circuit that would skip TX (`RigController.swift:497–569`). Only a minor
inefficiency (an unnecessary band re‑select on simplex). No action needed.

**Already at parity (recently fixed):** IC‑9700 SAT Main=RX/Sub=TX layout, and FT4 data mode
via `06 <mode>` + `1A 06` (both match OscarWatch's tested paths — see `cat-cardsat` notes).

---

## 3. Rotator parity & improvements

| Protocol | OscarWatch | OrbitDeck |
|---|---|---|
| GS‑232 A/B | ✓ | ✓ |
| Easycomm I/II/III | ✓ (II) | ✓ (I/II/III) |
| SPID Rot2Prog | ✓ | ✓ |
| rotctld (Hamlib) | ✗ (by design) | ✓ **[lead]** |
| PstRotator | ✗ | ✓ **[lead]** |
| Green Heron RT‑21 | ✓ (dual DCU‑1) | **✗ [gap]** |
| OZ9AAR URC (TCP/JSON) | ✓ | ✗ (niche) |
| SAEBRTrack | ✓ | ✗ (niche) |

Rotator defects/improvements:
1. **[gap] Green Heron RT‑21** (az/el via two DCU‑1 serial ports) — the most common controller
   OrbitDeck lacks; worth adding. URC/SAEBRTrack are niche (lower priority).
2. **[improve] Keyhole / zenith handling.** OscarWatch has a dedicated `KeyholePlanner` +
   slew‑rate config for high‑elevation (0–180° el) passes (flipped‑start to minimize keyhole
   loss). OrbitDeck has **flip mode + 450° overlap + time‑based pre‑position lead**
   (`RotatorController.swift`) — good, but no slew‑rate‑based (mechanical‑lag) lead. Consider a
   slew‑rate lead for fast overhead passes.
3. **[parity note]** Both are effectively **open‑loop** (position read is display‑only, no
   feedback correction). Fine, but note it.

---

## 4. Non‑CAT/rotator parity (context, lower priority for this build)

- **OrbitDeck [lead]:** SSTV decode, full‑duplex FT4 (+ audio‑domain Doppler), remote SSB/FM
  voice, pass recording (AAC), LoTW on‑device signing, on‑device everything (no PC).
- **OscarWatch has, OrbitDeck may lack [verify]:** per‑station **horizon mask** feeding pass
  prediction + polar plots; **voice/TTS "rising" announcements**; **.ics calendar export**;
  **mutual‑pass finder** (two‑station). OrbitDeck already has hams.at alerts
  (`HamsatAlertServiceTests`). These are tracker features, not CAT/rotator.

---

## 5. Recommended next‑build scope (CAT/rotator)

**Do first (CONFIRMED defects, high operator impact):**
- FM‑N narrow‑filter support for FM satellites (#2.1) — no narrow‑FM path exists today.
- TS‑2000 / TS‑790 SATL entry handshake (#2.2) — Kenwood full‑duplex rigs never enter sat mode.

**High‑value features:**
- FlexRadio SmartSDR CAT (the standout parity gap) — scope separately; TCP‑reachable on iOS.
- Green Heron RT‑21 rotator (#3.1).

**Refinements:**
- Post‑TCA receding‑leg Doppler lead (#2.3); dial settle/resume (#2.4); follow‑dial band guard
  (#2.5); CW‑uplink toggle (#2.6).

_Same‑band simplex was investigated and is already correct — not on the list._

_References:_ OscarWatch `/tmp/OscarWatch-Tracker/OscarWatch.Core/Radio/` and
`OscarWatch/Rotator/`; OrbitDeck `OrbitDeckIOS/CAT/` and `OrbitDeckIOS/Rotator/`. See memories
`cat-cardsat-orchestration`, `rotator-control-feature`, `cat-rig-control-feature`.
