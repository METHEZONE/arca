#!/usr/bin/env python3
import json
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np


def load_mono_float(path):
    tmp = Path("/tmp/arca_diarize_pcm_s16le.raw")
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(path), "-ac", "1", "-ar", "16000", "-f", "s16le", str(tmp)],
        check=True,
    )
    pcm = np.frombuffer(tmp.read_bytes(), dtype="<i2").astype(np.float32) / 32768.0
    return pcm, 16000


def frame_features(audio, sr, frame_ms=100):
    n = int(sr * frame_ms / 1000)
    frames = []
    for start in range(0, max(0, len(audio) - n + 1), n):
        x = audio[start:start + n]
        rms = float(np.sqrt(np.mean(x * x) + 1e-12))
        zcr = float(np.mean(np.abs(np.diff(np.signbit(x)))))
        spectrum = np.abs(np.fft.rfft(x * np.hanning(len(x))))
        freqs = np.fft.rfftfreq(len(x), 1 / sr)
        centroid = float((spectrum * freqs).sum() / (spectrum.sum() + 1e-9))
        frames.append((start / sr, rms, zcr, centroid))
    return frames


def diarize(path):
    audio, sr = load_mono_float(path)
    frames = frame_features(audio, sr)
    if not frames:
        return {"duration": 0, "segments": []}

    rms_values = np.array([f[1] for f in frames])
    threshold = max(float(np.percentile(rms_values, 65) * 0.45), 0.005)
    voiced = [f for f in frames if f[1] >= threshold]
    if not voiced:
        return {"duration": len(audio) / sr, "threshold": threshold, "segments": []}

    centroids = np.array([f[3] for f in voiced])
    median_centroid = float(np.median(centroids))

    labels = {}
    for t, rms, zcr, centroid in frames:
        if rms < threshold:
            labels[t] = "silence"
        else:
            labels[t] = "SPEAKER_00" if centroid <= median_centroid else "SPEAKER_01"

    segments = []
    last_label = None
    start = 0.0
    frame_step = 0.1
    for t, *_ in frames:
        label = labels[t]
        if last_label is None:
            last_label = label
            start = t
        elif label != last_label:
            if last_label != "silence" and t - start >= 0.2:
                segments.append({"start": round(start, 2), "end": round(t, 2), "speaker": last_label})
            start = t
            last_label = label
    end = frames[-1][0] + frame_step
    if last_label != "silence" and end - start >= 0.2:
        segments.append({"start": round(start, 2), "end": round(end, 2), "speaker": last_label})

    return {
        "duration": round(len(audio) / sr, 2),
        "method": "rough local energy + spectral centroid split, not pyannote-grade diarization",
        "threshold": threshold,
        "median_centroid": median_centroid,
        "segments": segments,
    }


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: rough_diarize_wav.py in.wav out.json")
    result = diarize(Path(sys.argv[1]))
    Path(sys.argv[2]).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
