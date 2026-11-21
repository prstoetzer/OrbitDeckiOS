# Third-party notices

## SatelliteKit

OrbitDeck iOS uses SatelliteKit, a Swift implementation of SGP4/SDP4.

Repository: `gavineadie/SatelliteKit`

The dependency is resolved by Swift Package Manager and is licensed under the MIT License.
No SatelliteKit source files are vendored into this repository.

## ft8_lib

FT4/FT8 encoding and decoding is provided by **ft8_lib** by Kārlis Goba, vendored
under `OrbitDeckIOS/DigitalModes/ft8_lib/` (the portable `ft8/`, `fft/` and
`common/monitor` sources; the libsndfile/portaudio demo files are excluded).

Repository: `kgoba/ft8_lib` — licensed under the MIT License (Copyright (c) 2018
Kārlis Goba). The full license text is in
`OrbitDeckIOS/DigitalModes/ft8_lib/LICENSE`.

## DeepCW

The default CW decoder runs the **DeepCW** neural network by e04, converted to
Core ML and bundled as `OrbitDeckIOS/DigitalModes/DeepCW/DeepCW.mlpackage`
(conversion tooling in `tools/deepcw/`). OrbitDeck's decoding pipeline is its own
Swift implementation, following the engine's MIT reference decoder.

Repository: `e04/deepcw-engine` (commit `79104fbe`) — licensed under the MIT
License (Copyright (c) 2026 e04). The full license text is in
`OrbitDeckIOS/DigitalModes/DeepCW/LICENSE`.

## d3-celestial

The constellation stick figures on the sky charts (`WorldMapData.constellationLines`)
come from **d3-celestial** by Olaf Frohn — Copyright (c) 2015 Olaf Frohn, licensed
under the BSD 3-Clause License. The full license text is shown in the app under Settings →
About → Acknowledgments.

## Data

- Yale Bright Star Catalog (BSC5) — public domain.
- Natural Earth — public domain.
- Weather data by Open-Meteo.com — CC BY 4.0.
