"""Synthesize a noisy CW WAV (PARIS timing) for decoder tests."""
import sys
import wave

import numpy as np

MORSE = {'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'F': '..-.', 'G': '--.', 'H': '....',
         'I': '..', 'J': '.---', 'K': '-.-', 'L': '.-..', 'M': '--', 'N': '-.', 'O': '---', 'P': '.--.',
         'Q': '--.-', 'R': '.-.', 'S': '...', 'T': '-', 'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-',
         'Y': '-.--', 'Z': '--..', '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
         '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.', '/': '-..-.', '?': '..--..'}


def keying(text, wpm, sr):
    dot = 1.2 / wpm
    env = []
    on = lambda n: env.extend([1.0] * int(n * dot * sr))
    off = lambda n: env.extend([0.0] * int(n * dot * sr))
    off(7)
    for word in text.split():
        for ci, ch in enumerate(word):
            code = MORSE[ch]
            for si, s in enumerate(code):
                on(1 if s == '.' else 3)
                if si < len(code) - 1:
                    off(1)
            if ci < len(word) - 1:
                off(3)
        off(7)
    return np.array(env, np.float32)


def main():
    text, wpm, snr_db, pitch, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
    sr = 48000
    env = keying(text, wpm, sr)
    k = int(0.005 * sr)
    ramp = np.convolve(env, np.ones(k) / k, mode='same')
    t = np.arange(len(env)) / sr
    tone = 0.3 * np.sin(2 * np.pi * pitch * t)
    noise = np.random.default_rng(4).normal(size=len(env))
    # SNR quoted in a 500 Hz bandwidth.
    noise *= np.sqrt(np.mean(tone ** 2) / (10 ** (snr_db / 10)) * (sr / 2) / 500.0)
    audio = np.clip(ramp * tone + noise, -1, 1)
    with wave.open(out, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes((audio * 32767).astype('<i2').tobytes())
    print(out, round(len(audio) / sr, 1), 's')


if __name__ == '__main__':
    main()
