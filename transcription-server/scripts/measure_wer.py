#!/usr/bin/env python3
"""Measure Pianissimo's WER on public Swedish speech, with and without preprocessing.

Runs on the CachyOS PC with the installed environment (see README, "Mäta
ordfelfrekvens"). Reads either a FLEURS sv_se folder (test.tsv + audio/) or a
folder of 16 kHz mono PCM16 *.wav files with same-named *.txt references.
All synthetic conditions are built in RAM; no audio file is written. Only
aggregated numbers are printed. Never point it at private recordings.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import sys
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402

from mio_transcription.evaluation import CONDITIONS, word_error_rate  # noqa: E402
from mio_transcription.preprocess import RATE, float_to_pcm, pcm_to_float, preprocess  # noqa: E402

MAX_SECONDS = 24
FORBIDDEN = (Path("/var/lib/mio-transcription"), Path("/etc"))


def read_wave(path):
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, RATE, "NONE"):
            return None
        return pcm_to_float(audio.readframes(audio.getnframes()))


def fleurs_items(folder):
    """FLEURS layout: test.tsv (id, file, raw text, normalized text, ...) and audio/**.wav."""
    files = {path.name: path for path in (folder / "audio").rglob("*.wav")}
    with open(folder / "test.tsv", newline="", encoding="utf-8") as table:
        for row in csv.reader(table, delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(row) >= 4 and row[1] in files:
                yield row[0], files[row[1]], row[2]


def pair_items(folder):
    for path in sorted(folder.rglob("*.wav")):
        reference = path.with_suffix(".txt")
        if reference.is_file():
            yield path.stem, path, reference.read_text(encoding="utf-8").strip()


def load(folder, limit):
    items = fleurs_items(folder) if (folder / "test.tsv").is_file() else pair_items(folder)
    loaded, skipped = [], 0
    for group, path, text in items:
        audio = read_wave(path)
        if audio is None or not text or len(audio) > MAX_SECONDS * RATE:
            skipped += 1
            continue
        loaded.append((group, audio, text))
        if len(loaded) >= limit:
            break
    return loaded, skipped


def build(condition, items, rng):
    """Yield (audio, reference) per condition; two-speaker mixes use different sentences."""
    speakers, make = CONDITIONS[condition]
    if speakers == 1:
        for _, audio, text in items:
            yield make([(audio, text)], rng)
        return
    for index, (group, audio, text) in enumerate(items):
        for other_group, other, other_text in items[index + 1:] + items[:index]:
            if other_group != group and len(audio) + len(other) - RATE // 2 <= MAX_SECONDS * RATE:
                yield make([(audio, text), (other, other_text)], rng)
                break


def transcribe(backend, audio):
    words = backend.transcribe(float_to_pcm(audio))
    return " ".join(word["text"] for word in words)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", type=Path, required=True,
                        help="FLEURS sv_se-mapp (test.tsv + audio/) eller mapp med .wav + .txt")
    parser.add_argument("--limit", type=int, default=100, help="högsta antal yttranden (standard 100)")
    parser.add_argument("--seed", type=int, default=1, help="slumpfrö för syntetiska villkor")
    parser.add_argument("--conditions", nargs="+", choices=list(CONDITIONS), default=list(CONDITIONS))
    parser.add_argument("--json", action="store_true", help="skriv resultatet som JSON")
    args = parser.parse_args()

    folder = args.data.resolve()
    if any(folder == path or path in folder.parents for path in FORBIDDEN):
        parser.error("välj en mapp med publikt testtal, inte tjänstens data eller konfiguration")
    items, skipped = load(folder, args.limit)
    if not items:
        parser.error("hittade inga 16 kHz mono PCM16-yttranden med referenstext (högst 24 s)")

    from mio_transcription.backend import Pianissimo
    backend = Pianissimo()
    backend.load()

    results = {}
    for condition in args.conditions:
        # Same seed per condition, so "utan" and "med" see identical synthetic audio.
        rng = np.random.default_rng(args.seed)
        references, plain, processed = [], [], []
        for audio, reference in build(condition, items, rng):
            references.append(reference)
            plain.append(transcribe(backend, audio))
            processed.append(transcribe(backend, preprocess(audio)))
        if references:
            results[condition] = {"yttranden": len(references),
                                  "utan": word_error_rate(references, plain),
                                  "med": word_error_rate(references, processed)}

    summary = {"modell": backend.metadata(), "överhoppade": skipped, "villkor": results}
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return
    meta = summary["modell"]
    print(f"Modell {meta['model']} @ {meta['revision'][:12]}; {len(items)} yttranden, {skipped} överhoppade.")
    print(f"{'Villkor':<20} {'Antal':>6} {'WER utan':>10} {'WER med':>10}")
    for condition, row in results.items():
        print(f"{condition:<20} {row['yttranden']:>6} {row['utan'] * 100:>9.1f}% {row['med'] * 100:>9.1f}%")


if __name__ == "__main__":
    os.umask(0o077)
    main()
