# Scope — FlexRadio control (SmartSDR TCP API)

Status: **scoping only, no code written.** Target: a future 0.9.x/1.0.

This scopes adding **FlexRadio** rig control to OrbitDeck for iOS so an operator can
Doppler-tune a FLEX‑6000/8000 series radio for satellite work. It builds directly on
the existing CAT subsystem (`OrbitDeckIOS/CAT/`) added in 0.9.12 — the same
`RigController`/tuning loop, Home card, tuning options and One‑True‑Rule read‑back —
and only adds a new transport + codec for Flex's protocol.

## Goals / scenarios

1. **Local‑network control** of a FLEX radio over Wi‑Fi/Ethernet (no SmartSDR PC
   in the loop), the same "network radio" story as the IC‑705/IC‑9700 path.
2. **Downlink + uplink via two slices.** A FLEX is a single transceiver, so drive a
   **downlink slice** (RX) and an **uplink slice** (TX) and Doppler‑correct both.
   (See the duplex caveat below — 6000‑series hardware is not true full duplex.)
3. **Single‑leg use** — one slice for downlink‑only (or uplink‑only) operation.
4. Reuse everything already built: per‑satellite calibration, passband offset,
   transverter LO, deadbands, predictive lead, and follow‑the‑dial.

Models: FLEX‑6300, 6400(M), 6500, 6600(M), 6700, and the 8000 series. They share the
SmartSDR TCP API; per‑model differences are minor (slice/antenna counts).

## Protocol (recommended transport): SmartSDR TCP/IP API, LAN only

FlexRadio's local API is a **plain‑text TCP command/status protocol** on **port
4992**, plus **VITA‑49 UDP discovery** on 4992. No audio/DAX is needed for CAT.

- **Discovery:** radios periodically broadcast a VITA‑49 discovery datagram on UDP
  4992 carrying IP, model, serial, nickname, version and status. OrbitDeck can listen
  for these to offer a pick‑list, or the operator can type the radio's **IP** (the
  reliable fallback, exactly like the Icom network `host` field).
- **Connect:** open a TCP socket to `radioIP:4992`. On connect the radio emits a
  version line (`V…`) and a client‑handle line (`H<hex>`).
- **Commands:** client sends `C[D]<seq>|<command>\n`; the radio answers
  `R<seq>|<hexStatus>|<reply>`. Asynchronous state arrives as `S<handle>|<object
  key=value …>` (status) and `M<code>|<text>` (messages).
- **Subscribe** to state once: `sub slice all` (and `sub tx all` if PTT/TX state is
  wanted).
- **Tune a slice:** `slice tune <index> <freqMHz>` (frequency in MHz, ~6 decimals,
  e.g. `slice tune 0 145.925000`).
- **Set mode:** `slice set <index> mode=USB` (LSB/USB/CW/FM/DIGU/DIGL…).
- **Slice roles:** identify existing slices with `slice list`; create one with
  `slice create …` if needed; make a slice the transmitter with `slice set <index>
  tx=1`. PTT (not used by OrbitDeck) would be `xmit 1|0`.
- **No authentication on the LAN.** FlexRadio's **SmartLink** (remote‑over‑internet)
  requires an OAuth/JWT token from FlexRadio's servers and a relayed connection —
  **out of scope**; OrbitDeck would support **local network only**.

Authoritative references to verify byte/format details against: FlexRadio's SmartSDR
TCP/IP Ethernet API guide and the FlexLib / **flexlib‑python** open‑source clients
(command grammar, discovery packet layout, status parsing).

## Proposed architecture (slots into the existing CAT code)

- **`RigFamily.flex`** — a new dialect family alongside `civ`/`yaesu…`/`kenwood…`.
- **`FlexTransport`** (new, `CAT/FlexTransport.swift`) — an `NWConnection(.tcp)`
  client on a dedicated queue, conforming to the existing `CATTransport` protocol.
  Unlike the byte transports it is **line‑oriented**: it appends `\n`‑terminated
  commands, tracks the `C<seq>`→`R<seq>` reply, and parses `S…`/`V…/H…` lines. It can
  expose the current slice frequency for the One‑True‑Rule read‑back by watching
  slice status rather than polling.
- **`FlexCodec`** (small, pure) — builds the text commands (`slice tune`, `slice set
  mode=…`) and maps `RigMode` → Flex mode tokens; parses a slice's `RF_frequency`
  from status for read‑back. Pure ⇒ unit‑testable like the CI‑V/Kenwood codecs.
- **`RadioSpec` entries** — the FLEX models, `family: .flex`, `hasLan: true`, network
  transport only (no CI‑V address, no serial rate). `RadioCatalog` gains a "Flex"
  group.
- **`RigController` routing** — for a Flex link, `sendFreq(leg:)` issues `slice tune`
  on the leg's slice and (at engage) `slice set mode`. Downlink → the RX slice,
  uplink → the TX slice; a single‑leg config drives one slice. Everything else — the
  GCD‑timer tuning loop, deadbands, transverter LO, calibration, passband, follow —
  is unchanged.
- **Config** — reuse `RigSlot`: `transport = .network`, `host` = radio IP,
  `port` = 4992. Add optional **slice index** fields (downlink slice / uplink slice),
  defaulting to auto‑resolve from `slice list` (RX slice for downlink, TX slice for
  uplink). No password (LAN API is unauthenticated).
- **UI** — the Rig Control settings screen gains Flex as a network radio; a
  **discovery pick‑list** (if implemented) or manual IP. The Home card is unchanged.

## Duplex / slice model

- **Full duplex is limited.** FLEX‑6000 hardware transmits and receives on one
  conversion chain; it is not a true full‑duplex satellite radio like an IC‑9700.
  OrbitDeck can keep an RX slice (downlink) and a TX slice (uplink) both tuned and
  Doppler‑corrected, but the radio mutes RX while transmitting. Document this clearly
  and default a single Flex to a chosen leg; treat "both" as "keep both slices
  tuned," not "simultaneous full duplex." A true full‑duplex station still pairs two
  radios (e.g. Flex downlink + a second rig uplink), which the dual‑radio model
  already supports.
- **Follow‑the‑dial** works well here: slice frequency arrives in status updates, so
  the One‑True‑Rule read‑back can be event‑driven (no per‑cycle query).

## iOS platform constraints

- **TCP via Network.framework** — straightforward; reuses the Local Network privacy
  permission already added for Icom network CAT (`NSLocalNetworkUsageDescription`).
- **Discovery** — listening for the UDP broadcast may require additional handling; if
  FlexRadio's discovery is multicast rather than subnet broadcast, iOS needs the
  **`com.apple.developer.networking.multicast`** entitlement (a request‑gated Apple
  entitlement). **Manual IP entry avoids this entirely** and should ship first;
  discovery is a nice‑to‑have follow‑up.
- **Foreground only** — same as all CAT: iOS suspends networking in the background,
  so pair with "Keep screen awake on Home."
- **Security** — the LAN API is unauthenticated; this is a same‑network control
  channel. SmartLink (which would involve OAuth tokens and FlexRadio's relay) is out
  of scope and would be a separate, larger effort with its own privacy review.

## Effort & phasing

1. **Foundation** — `FlexTransport` (TCP connect, line framing, `C/R/S/V/H` parsing,
   keepalive), `FlexCodec` (tune/mode/mode‑map/status‑parse), one FLEX model in the
   catalog, manual‑IP config. Prove single‑slice downlink Doppler on real hardware.
   *This is the bulk of the work — a new line‑oriented transport.*
2. **Two‑slice** — resolve/select the RX and TX slices, mode per slice, uplink leg;
   the duplex caveat surfaced in the UI; event‑driven follow from slice status.
3. **Discovery + polish** — VITA‑49 discovery pick‑list (guarded by the multicast
   entitlement question), full model list, error surfacing, unit tests for the codec.

## Top risks / unknowns

- **Slice lifecycle** — whether to require the operator to have slices already
  created in SmartSDR vs. creating them over the API, and how to pick the right
  index. Needs a decision and hardware testing.
- **Full‑duplex expectation** — set operator expectations; Flex is not IC‑9700‑style
  full duplex.
- **Discovery on iOS** — broadcast vs multicast and the entitlement implication;
  manual IP is the safe default.
- **Status‑parse completeness** — the `S…` grammar is broad; parse only the slice
  frequency/mode fields needed, tolerantly.
- **No sandbox** — like the Icom network path, this needs a real FLEX to validate.

## Non‑goals

SmartLink/remote‑over‑internet, DAX/audio streaming, panadapter/waterfall, memories,
amplifier/ATU/antenna control, and non‑satellite operating are out of scope.

## References

- FlexRadio SmartSDR TCP/IP Ethernet API documentation (command grammar, discovery,
  status objects).
- `flexlib‑python` and the .NET **FlexLib** (reference clients for the command set and
  VITA‑49 discovery parsing).
- OrbitDeck's existing CAT subsystem — `OrbitDeckIOS/CAT/` — which this reuses; see
  also `SCOPE_ICOM_LAN.md` for the analogous network‑CAT scoping.
