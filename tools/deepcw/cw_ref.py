"""Independent DeepCW streaming decoder (prototype for the Swift port).

Backends: 'onnx' runs each window at its true length; 'coreml' always runs a fixed
801-frame (12 s) window, left-padding short windows with silence and dropping the
padded output frames.
"""
import json
import math
import sys
import wave

import numpy as np

SR = 3200
FFT = 256
HOP = 48
STRIDE = 2
OUT_HOP = HOP * STRIDE          # 96 samples per output frame
WINDOW_SAMPLES = 12 * SR        # 38400 -> 801 spectrogram frames
FIXED_FRAMES = 1 + WINDOW_SAMPLES // HOP
STEP = SR                       # decode every 1 s
FIRST = 2 * SR
LEFT_CONTEXT = round(4 * SR / OUT_HOP)
FREEZE_GUARD = round(2 * SR / OUT_HOP)
LEFT_RAMP, RIGHT_RAMP = 2.0, 1.0
WORD_GAP = math.ceil(134 / STRIDE)
FPS = SR / OUT_HOP


def read_wav(path):
    with wave.open(path, 'rb') as w:
        sr = w.getframerate()
        a = np.frombuffer(w.readframes(w.getnframes()), '<i2').astype(np.float32) / 32768
    n = int(round(len(a) * SR / sr))
    pos = np.arange(n) * sr / SR
    lo = np.floor(pos).astype(int)
    hi = np.minimum(lo + 1, len(a) - 1)
    f = (pos - lo).astype(np.float32)
    return a[lo] * (1 - f) + a[hi] * f


def spectrogram(audio, meta):
    start = int(math.ceil(meta['spectrogram_min_freq_hz'] / (SR / FFT)))
    stop = int(math.floor(meta['spectrogram_max_freq_hz'] / (SR / FFT))) + 1
    padded = np.pad(audio, (FFT // 2, FFT // 2), mode='reflect')
    win = (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(FFT) / FFT)).astype(np.float32)
    n = 1 + (len(padded) - FFT) // HOP
    mags = np.stack([np.abs(np.fft.rfft(padded[i * HOP:i * HOP + FFT] * win))[start:stop] for i in range(n)])
    q = meta['noise_level_quantile']
    flat = np.sort(mags.ravel())
    noise = max(flat[math.floor(q * (len(flat) - 1))] / math.sqrt(-2 * math.log(1 - q)), flat[-1] * 1e-3, 1e-5)
    return np.log1p(mags / noise).astype(np.float32)


def log_softmax(x):
    m = x.max(-1, keepdims=True)
    return x - (m + np.log(np.exp(x - m).sum(-1, keepdims=True)))


def smoothstep(v):
    t = np.clip(v, 0, 1)
    return t * t * (3 - 2 * t)


class Backend:
    def __init__(self, kind, path):
        self.kind = kind
        if kind == 'onnx':
            import onnxruntime as ort
            self.s = ort.InferenceSession(path)
        else:  # 'coreml' or 'coreml-ext'
            import coremltools as ct
            self.m = ct.models.MLModel(path, compute_units=ct.ComputeUnit.ALL)

    def run(self, spec):
        t = len(spec)
        if self.kind == 'onnx':
            return self.s.run(None, {'spectrogram': spec[None, None]})[0][0]
        x = np.zeros((FIXED_FRAMES, spec.shape[1]), np.float32)
        x[FIXED_FRAMES - t:] = spec
        out = self.m.predict({'spectrogram': x[None, None]})['log_probs'][0]
        # Output frame k covers input frames 2k..; drop frames that came from padding.
        pad_out = (FIXED_FRAMES - t) // STRIDE
        expected = (t - 1) // STRIDE + 1
        return out[len(out) - expected:] if pad_out >= 0 else out


class Stitcher:
    def __init__(self, meta):
        self.chars = meta['chars']
        self.blank = meta['blank_index']
        self.space = self.chars.index(' ') if ' ' in self.chars else -1
        self.k = meta['num_classes']
        self.base = 0
        self.sums = np.zeros((0, self.k), np.float32)
        self.w = np.zeros(0, np.float32)
        self.covered = self.frozen = self.committed = 0
        self.prev = 'none'
        self.blanks = 0
        self.has_text = False

    def context_start(self):
        return max(0, self.frozen - LEFT_CONTEXT)

    def window_start(self, end_sample):
        return max(self.context_start(), math.ceil((end_sample - WINDOW_SAMPLES) / OUT_HOP))

    def add(self, start, logits, final):
        n = len(logits)
        end = start + n
        grow = end - self.base - len(self.w)
        if grow > 0:
            self.sums = np.vstack([self.sums, np.zeros((grow, self.k), np.float32)])
            self.w = np.concatenate([self.w, np.zeros(grow, np.float32)])
        lp = log_softmax(logits.astype(np.float32))
        pad = np.pad(lp, ((1, 1), (0, 0)), constant_values=-np.inf)
        dil = np.maximum(np.maximum(pad[:-2], pad[1:-1]), pad[2:])
        dil[:, self.blank] = lp[:, self.blank]
        lp = log_softmax(dil)
        frames = np.arange(max(0, self.frozen - start), n)
        left = np.inf if start == 0 else frames / FPS
        right = np.inf if final else (n - 1 - frames) / FPS
        wt = np.broadcast_to(np.maximum(1e-3, smoothstep(left / LEFT_RAMP) * smoothstep(right / RIGHT_RAMP)), frames.shape)
        rows = start + frames - self.base
        self.sums[rows] += wt[:, None] * lp[frames]
        self.w[rows] += wt
        self.covered = max(self.covered, end)
        self.frozen = self.covered if final else max(self.frozen, end - FREEZE_GUARD)

    def scores(self, a, b):
        r = slice(a - self.base, b - self.base)
        w = self.w[r]
        s = np.full((b - a, self.k), -30.0, np.float32)
        s[:, self.blank] = 0
        c = w > 0
        s[c] = self.sums[r][c] / w[c, None]
        return s

    def take(self, final):
        a = self.committed
        if self.covered - a <= 0:
            return ''
        sc = self.scores(a, self.covered)
        arg = sc.argmax(-1)
        idx = arg.copy()
        prev = -2 if self.prev == 'char' else (self.space if self.prev == 'space' else -1)
        f = 0
        while f < len(idx):
            if idx[f] != self.blank:
                prev = int(idx[f]); f += 1; continue
            s0 = f
            while f < len(idx) and idx[f] == self.blank:
                f += 1
            nxt = int(idx[f]) if f < len(idx) else -1
            run = f - s0 + (self.blanks if s0 == 0 else 0)
            if run >= WORD_GAP and prev not in (-1, self.space) and nxt >= 0 and nxt != self.space:
                idx[s0:f] = self.space
        spans, last = [], -1
        for fr, i in enumerate(idx):
            i = int(i)
            if i == self.blank:
                last = -1; continue
            if i == last:
                spans[-1][2] = fr + a; continue
            last = i
            spans.append([self.chars[i], fr + a, fr + a])
        limit = math.inf if final else self.frozen
        count = 0
        for j, sp in enumerate(spans):
            if sp[2] + 1 >= limit:
                break
            if sp[0] != ' ':
                count = j + 1
        text = ''
        if count:
            starts_word = not self.has_text or self.prev == 'space'
            out, pend = [], False
            lead = starts_word
            for sp in spans[:count]:
                if sp[0] == ' ':
                    if out: pend = True
                    else: lead = True
                    continue
                if pend: out.append(' '); pend = False
                out.append(sp[0])
            text = (' ' if lead else '') + ''.join(out)
            self.has_text = True
            self.committed = spans[count - 1][2] + 1
            self.prev, self.blanks = 'char', 0
        rest = spans[count:]
        nxt = next((s for s in rest if s[0] != ' '), None)
        release = min(self.covered if final else self.frozen, nxt[1] if nxt else math.inf) - 1
        p, bl = self.prev, self.blanks
        fr = self.committed
        while fr < release:
            if arg[fr - a] == self.space:
                p, bl = 'space', 0
            else:
                bl += 1
            fr += 1
        if release > self.committed:
            self.prev, self.blanks = p, bl
            self.committed = int(release)
        drop = min(self.committed - self.base, len(self.w))
        if drop > 0:
            self.sums, self.w = self.sums[drop:], self.w[drop:]
            self.base += drop
        return text


def decode(audio, meta, backend):
    st = Stitcher(meta)
    out = []

    def window(start, end, final):
        run_start = start
        if backend.kind == 'coreml-ext':
            # Fill the fixed 12 s window with real earlier audio where it exists.
            run_start = max(0, math.ceil((end - WINDOW_SAMPLES) / OUT_HOP))
            run_start = min(run_start, start)
        spec = spectrogram(audio[run_start * OUT_HOP:end], meta)
        logits = backend.run(spec)
        st.add(start, logits[start - run_start:], final)
        out.append(st.take(final))

    end = FIRST
    while end < len(audio):
        window(st.window_start(end), end, False)
        end += STEP
    while True:
        start = st.context_start()
        end = min(len(audio), start * OUT_HOP + WINDOW_SAMPLES)
        window(start, end, end >= len(audio))
        if end >= len(audio):
            break
    return ''.join(out).strip()


if __name__ == '__main__':
    kind, model, meta_path, wav = sys.argv[1:5]
    meta = json.load(open(meta_path))
    print(decode(read_wav(wav), meta, Backend(kind, model)))
