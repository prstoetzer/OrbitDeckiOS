# CardSat BASIC compatibility corpus

These **13 listings** are copied from the current CardSat `examples/basic` suite and are included as OrbitDeck iOS Tiny BASIC compatibility fixtures.

The self-contained/parser-focused group is `CALLPARSE.BAS`, `DXPATH.BAS`, `PASSTATS.BAS`, `SIEVE.BAS`, `HARMONO.BAS`, `STARFLD.BAS`, and `MANDEL.BAS`. They exercise strings/input/named arrays, numerical DXCC/geometry, pass arrays, anonymous arrays, control flow, DATA/READ and graphics.

0.9.5 adds six real live-data fixtures: `PASSES.BAS`, `GROUND.BAS`, `SUNMOON.BAS`, `BELT.BAS`, `DECAY.BAS`, and `DOPPLER.BAS`. The host regression places a deterministic moving test satellite over a test station so these programs execute their positive/live paths: pass lookahead, catalog `SATSEL`, subpoints, Sun/Moon + sidereal/magnetic data, decay and geomagnetic snapshots, and `SATSEL` → `TXSEL` → corrected receive/transmit frequencies.

Cross-platform limits are deliberate. OrbitDeck does not fabricate Cardputer battery, heap, charging, or GPS hardware telemetry. CardSat's belt example is based on its IGRF-14 field; the iOS host provides a documented planning-grade centered-dipole approximation for `LSHELL`, `BRATIO`, `BFIELD`, `INBELT`, `INSAA`, and `MAGDECL`, so the language/API is portable without claiming identical magnetic-field precision.
