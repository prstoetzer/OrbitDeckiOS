# Scope — Icom network CAT control (IC-9700 / IC-705)

Status: **scoping only, no code written.** Target: 0.9.12+.

This document scopes adding network CAT control of Icom radios to OrbitDeck for
iOS, so an operator can Doppler-tune their rig from the app over WiFi. It draws on
CardSat's reverse-engineered protocol notes
(`docs/interfaces/ICOM_LAN_PROTOCOL.md`, `CIV_INTERFACE.md`) — CardSat is the
firmware reference implementation. See <https://github.com/prstoetzer/CardSat>.

## Goals / scenarios

1. **IC-9700** — the radio has a built-in Ethernet (LAN) port. With an inexpensive
   **Ethernet-to-WiFi bridge** on that port, the app reaches the radio's IP over
   WiFi and controls it. Full-duplex satellite mode: drive MAIN (uplink) and SUB
   (downlink) VFOs and Doppler-correct both.
2. **IC-705, single radio** — the 705 has built-in WiFi (no bridge needed).
   Control **one leg** (uplink *or* downlink) — half-duplex operating.
3. **Two IC-705s** — one as the uplink radio, one as the downlink radio; two
   independent sessions Doppler-corrected together for full duplex.

## Key finding: one protocol covers all three

Both the IC-9700's LAN port and the IC-705's WiFi speak Icom's **RS-BA1 network
remote protocol (UDP)**. A single client implementation therefore serves every
scenario above; only a per-radio **role** (uplink / downlink / both) differs. The
IC-9700 simply needs the Ethernet-to-WiFi bridge to put its LAN port on the same
WiFi network as the iPhone/iPad; the IC-705 is already on WiFi.

## Transport (recommended): native RS-BA1 UDP, CAT-only

The RS-BA1 link exposes three UDP streams: **Control (50001)**, **Serial/CI-V
(50002)** and **Audio (50003)**. OrbitDeck needs CAT only, so it opens **Control +
Serial** and never opens Audio.

Session lifecycle (per CardSat's byte-exact spec):

1. **Bootstrap** each stream: are-you-there → i-am-here (learn the radio's session
   id) → are-you-ready → ready.
2. **Control-stream auth:** login (username/password via Icom's `passcode()`
   obfuscation) → auth (magic `0x02`, then `0x05`) → capture the capabilities and
   auth ids → **ConnInfo** (a host-originated packet that is what actually makes
   CI-V start flowing) → ConnInfo reply.
3. **Serial stream:** bootstrap, then **Open** (magic `0x05`).
4. **Keepalive discipline (strict):** idle packets every ~100 ms (backing off to
   1 s), periodic pings, and prompt replies to the radio's pings, or the radio
   drops the link. Handle retransmit requests. Re-auth every 60 s.
5. **Teardown:** de-auth, close serial, disconnect both streams.

On the serial stream we tunnel **raw CI-V frames** — identical to a wired CI-V
connection. Commands needed:

| Purpose | CI-V | Notes |
|---|---|---|
| Set frequency | `0x05` | BCD, per-VFO after a band select |
| Set mode | `0x06` | LSB/USB/CW/FM as appropriate |
| Select MAIN / SUB | `0x07 D0` / `0x07 D1` | the IC-9700 dual-VFO satellite pair |
| Read frequency | `0x03` | optional — enables a "tune to the dial" workflow |

IC-9700 CI-V address `0xA2`; host/controller `0xE0`. These are the same frames
CardSat already sends over wired CI-V — only the transport changes.

## Proposed architecture (Swift / iOS)

- **`RigLinkActor`** (one per radio) — an `actor` wrapping two
  `Network.framework` `NWConnection(.udp)` sockets (control + serial), running the
  RS-BA1 state machine and keepalive on a dedicated queue. Exposes async
  connect/disconnect and a `sendCIV(_:)` that serializes queries (echo + response,
  one outstanding at a time) with a timeout.
- **`CIVCodec`** — build/parse CI-V frames (BCD frequency, mode, band select, ACK
  `0xFB` / NAK `0xFA`).
- **`RigController`** — owns 1–2 links, maps **roles** to which link + VFO receives
  which Doppler-corrected frequency, and runs a ~500 ms tuning loop. It **reuses
  the existing** `OrbitPredictor.dopplerFrequencies`, the per-satellite calibration
  (`OrbitStore.downlinkCalibrationHz`), and the passband offset already surfaced on
  Home/Radio — so CAT tunes to exactly what those screens display.
- **Config / persistence** — a `RigProfile` (model, host, ports, role, VFO
  convention) stored in `StorePreferences`; **credentials in the Keychain** via the
  existing `OrbitSecretStore` (as QRZ/Space-Track already are).
- **UI** — a new **Rig Control** screen under *Operating Tools*: add/edit radios,
  connect/disconnect, live link status, current DL/UL dials. It drives the same
  selected satellite/transponder the rest of the app tracks.

## iOS platform constraints (important)

- **Local Network permission.** LAN UDP triggers the iOS Local Network privacy
  prompt; the app needs `NSLocalNetworkUsageDescription`. Connections are
  direct-IP (no Bonjour) but still require the entitlement/prompt.
- **Foreground only.** iOS suspends networking in the background and RS-BA1's
  keepalive is strict, so CAT works only while the app is foreground. This pairs
  naturally with the existing **Keep screen awake on Home** option — the Rig
  Control screen should keep the screen awake while connected and make the
  limitation explicit.
- **Security.** RS-BA1's `passcode()` is obfuscation, not encryption; this is a
  same-LAN control channel. Store credentials in the Keychain and document that it
  is a local-network feature.
- **Operator setup.** The radio's network control must be enabled with a network
  user/password configured (Icom "Network" menu); the IC-9700 needs the
  Ethernet-to-WiFi bridge on its LAN jack. These become documented prerequisites.

## Effort & phasing

1. **Foundation** — RS-BA1 UDP client (control + serial, login/auth, ConnInfo,
   keepalive, retransmit) plus `CIVCodec` set-frequency. Prove it on a single
   IC-705 downlink. *This is the bulk of the work — the session/keepalive state
   machine.*
2. **Full duplex on one radio** — IC-9700 MAIN/SUB band select, mode set, Doppler
   on both legs; the Rig Control screen.
3. **Two-radio** — dual IC-705 (independent uplink/downlink links), optional
   read-back for a "tune to the dial" mode, UI polish and error surfacing.

## Top risks / unknowns

- **Audio-stream tolerance** — CardSat flags exactly one thing to verify against
  real hardware: whether the radio tolerates the audio stream never being opened.
  Fallback if not: open port 50003, complete its bootstrap, and discard all audio.
- **iOS Local Network UX** and the foreground-only limitation.
- **Keepalive / retransmit correctness** under WiFi jitter — needs real-hardware
  testing on an IC-9700 and IC-705.
- **Per-radio credential setup** friction for operators.

## Simpler alternative (worth offering)

A **serial-to-TCP WiFi bridge** on the radio's CI-V (REMOTE) or USB serial port
exposes **raw CI-V over a plain TCP socket** — no session, no auth, no keepalive,
far less code (open a socket, send/receive CI-V frames). It is a different, cheap
serial bridge (not the radio's native network mode) and works for any CI-V radio,
but it doesn't use the built-in LAN/WiFi. This is a materially lower-effort path if
that hardware is acceptable, and could ship first while the native RS-BA1 backend
is built.

## Non-goals

Audio streaming, memory/scope/other rig features, non-Icom rigs, and rotator
control are out of scope for this feature.

## Open questions for the operator

- Is the native RS-BA1 backend the priority, or is the simpler raw-CI-V-over-TCP
  serial-bridge path acceptable for a first release?
- Confirm the exact bridge hardware intended for the IC-9700 (any Ethernet client
  bridge on the LAN jack should work).
- Read-back / "tune to the dial" — needed in the first version, or later?

## References

- CardSat `docs/interfaces/ICOM_LAN_PROTOCOL.md` (byte-exact RS-BA1 UDP spec) and
  `CIV_INTERFACE.md`.
- Reference clients: `nonoo/kappanhang` (Go), `wfview` (C++),
  `microenh/NetworkIcom` (Swift — closest to this platform).
