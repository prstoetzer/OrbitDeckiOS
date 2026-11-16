# DeepCW model for OrbitDeck

OrbitDeck's default CW decoder runs [DeepCW](https://github.com/e04/deepcw-engine) by e04
(MIT License, relicensed from AGPL-3.0 at commit `79104fbe`, 2026-10-26). The Core ML package
`OrbitDeckIOS/DigitalModes/DeepCW/DeepCW.mlpackage` is converted from that commit's
`model.onnx` (SHA-256 `cd5ee381…28773ae`). Its license is in
`OrbitDeckIOS/DigitalModes/DeepCW/LICENSE` and is shown in Settings → About →
Acknowledgments.

## Rebuilding the model

```bash
python3 -m venv venv
./venv/bin/pip install "numpy<2.1" onnx onnxruntime onnx2torch "torch==2.7.0" coremltools
./venv/bin/python convert_deepcw.py model.onnx DeepCW.mlpackage
```

`convert_deepcw.py` rewrites the ONNX graph into plain float ops (quantize/dequantize,
`Reshape allowzero`, the ScatterND positional encoding, `Split` sizes), then converts
ONNX → PyTorch → Core ML. It checks every stage against ONNX Runtime. The traced model has
a fixed 801-frame (12 s) input, which is the window the app runs; shorter windows are
left-padded with silence. It stays float32: a float16 build dropped characters at 10 dB
SNR.

## Reference decoder and test audio

- `cw_ref.py`: Python version of the app's streaming pipeline (resample to 3.2 kHz,
  STFT, noise-quantile log1p normalization, 12 s windows every second, blended CTC
  posteriors, greedy decoding). Run it with `onnx` (true-length windows) or `coreml`
  (fixed 801-frame windows) to compare backends:
  `python cw_ref.py coreml DeepCW.mlpackage model.onnx.json test.wav`
- `make_cw.py`: synthesizes noisy CW (`text wpm snr_db pitch out.wav`; SNR in 500 Hz).

On synthesized CW, the Core ML and ONNX backends copy identically at 10 dB and above
and are within noise of each other at 6–8 dB. The Swift port (`DeepCW*` types in
`DigitalModes/FT4Engine.swift`) matches `cw_ref.py`'s spectrogram to within 2e-3; its
tests are in `OrbitDeckIOSTests/DeepCWTests.swift`.
