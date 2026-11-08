# Third-party notices

## SatelliteKit

OrbitDeck iOS uses SatelliteKit, a Swift implementation of SGP4/SDP4.

Repository: `gavineadie/SatelliteKit`

The dependency is resolved by Swift Package Manager and is licensed under the MIT License.
No SatelliteKit source files are vendored into this source bundle.

## ft8_lib

FT4/FT8 encoding and decoding is provided by **ft8_lib** by Kārlis Goba, vendored
under `OrbitDeckIOS/DigitalModes/ft8_lib/` (the portable `ft8/`, `fft/` and
`common/monitor` sources; the libsndfile/portaudio demo files are excluded).

Repository: `kgoba/ft8_lib` — licensed under the MIT License (Copyright (c) 2018
Kārlis Goba). The full license text is in
`OrbitDeckIOS/DigitalModes/ft8_lib/LICENSE`.

## d3-celestial

The constellation stick figures on the sky charts (`WorldMapData.constellationLines`)
come from **d3-celestial** by Olaf Frohn — Copyright (c) 2015 Olaf Frohn, licensed
under the BSD 3-Clause License. The full license text is shown in the app under
About → Acknowledgments.

## Data

- Yale Bright Star Catalog (BSC5) — public domain.
- Natural Earth — public domain.
- Weather data by Open-Meteo.com — CC BY 4.0.
