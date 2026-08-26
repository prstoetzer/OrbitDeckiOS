# OrbitDeck iOS/iPadOS 0.9.13 — antenna rotator control

Build 1. This release remains below 1.0. It follows 0.9.12 (2).

## Summary

0.9.13 adds **antenna rotator control**: OrbitDeck can now steer an az/el rotator
to follow the selected satellite across the whole pass — over a Bluetooth LE
serial adapter or over the network — mirroring how rig (CAT) control works. It
also refines both the rig and rotator Home cards for a cleaner, consistent look.

## Rotator control

- **Steer an az/el antenna rotator from OrbitDeck** to track the selected
  satellite. Configure it in Settings → Rotator control; control it from a new
  **Rotator** card on Home (connect/disconnect, commanded azimuth/elevation, and
  the current mode — Tracking, Pre-positioning or Parked).
- **Protocols** (ported byte-for-byte from CardSat): Yaesu **GS-232A/B**,
  **Easycomm I / II / III**, and **SPID Rot2Prog (MD-01/02)** over a BLE serial
  adapter; **rotctld** (Hamlib NET rotctl, TCP, default port 4533) and
  **PstRotator** (UDP, default port 12000) over the network. rotctld covers
  virtually every rotator Hamlib supports.
- **Pointing:** pre-position to the AOS bearing before the pass (configurable
  lead), park on LOS and on disconnect, a deadband to suppress needless moves, a
  minimum-elevation gate, and an adjustable update rate.
- **Alignment:** azimuth/elevation offsets, magnetic-vs-true correction (subtracts
  local declination when your controller is referenced to magnetic north), and a
  park position.
- **Axis handling:** 0–360°, −180…+180°, or 0–450° with a lookahead pre-commit to
  the upper turn to avoid a cable-wrap at North; and **flip mode** (az +180°,
  el 180−el) for near-overhead passes, applied only to passes that would otherwise
  cross the azimuth seam.
- On the fire-and-forget UDP path (PstRotator) a short keep-alive resends the
  target to self-heal a dropped datagram; reliable transports (rotctld/TCP and BLE
  serial) send only when the target actually moves past the deadband, so an
  unchanged position is never re-issued.
- Validated end-to-end against Hamlib's dummy rotator (`rotctld -m 1`) and against
  PstRotator's documented UDP command. Serial protocols are byte-faithful to
  CardSat and await on-hardware confirmation.
- Bluetooth Classic (SPP) adapters are not supported on iOS; use a BLE UART
  adapter for serial rotators, or reach the rotator over the network with rotctld.

## Rig & rotator Home cards

- Unified the two control cards behind a shared status header: a single line with
  the connection dot, the status, and the Connect/Disconnect button, plus a
  subtitle describing the configured link.
- Consistent wording across both cards ("Not connected" / "Connecting…" /
  "Connected"); the rotator no longer said "Disconnected."
- The rig card no longer shows an empty second-radio slot in single-radio mode —
  per-radio rows appear only for a two-radio station.

## Privacy

- Rotator control communicates directly with your rotator or its host computer
  over Bluetooth LE or your local Wi-Fi network, only when you connect; nothing is
  sent to the developer. See the privacy policy.
