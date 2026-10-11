"""WER and synthetic "muffled conversation" helpers for scripts/measure_wer.py.

Pure numpy and RAM only. Used with public read speech (e.g. FLEURS sv_se),
never with Mio recordings: Mio stores no raw audio to begin with.
"""
import re
import unicodedata

import numpy as np

from .preprocess import RATE, butterworth_lowpass_gain, zero_phase_filter


def normalize_text(text):
    """Swedish scoring form: NFC, lowercase, punctuation to spaces, single spaces.

    Letters (including å, ä, ö, é) and digits are kept. Numbers are not spelled
    out, so "3" against "tre" counts as an error on both sides of a comparison.
    """
    text = unicodedata.normalize("NFC", text).lower()
    text = re.sub(r"[^\w\s]|_", " ", text)
    return text.split()


def edit_distance(reference, hypothesis):
    """Word-level Levenshtein distance (substitutions + deletions + insertions)."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, 1):
        current = [i] + [0] * len(hypothesis)
        for j, hyp_word in enumerate(hypothesis, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1,
                             previous[j - 1] + (ref_word != hyp_word))
        previous = current
    return previous[-1]


def word_error_rate(references, hypotheses):
    """Corpus WER: total edits over total reference words, after normalization."""
    if len(references) != len(hypotheses):
        raise ValueError("references and hypotheses differ in length")
    errors = words = 0
    for reference, hypothesis in zip(references, hypotheses):
        reference, hypothesis = normalize_text(reference), normalize_text(hypothesis)
        errors += edit_distance(reference, hypothesis)
        words += len(reference)
    if words == 0:
        raise ValueError("no reference words")
    return errors / words


def rms_dbfs(audio):
    audio = np.asarray(audio, dtype=np.float64)
    return float(20 * np.log10(max(np.sqrt(np.mean(audio ** 2)) if audio.size else 0.0, 1e-12)))


def attenuate(audio, decibels):
    return (np.asarray(audio, dtype=np.float64) * 10 ** (-abs(decibels) / 20)).astype(np.float32)


def lowpass(audio, cutoff=3000.0, order=4):
    """Zero-phase Butterworth-shaped low-pass: speech through a jacket or wall."""
    return zero_phase_filter(audio, lambda f: butterworth_lowpass_gain(f, cutoff, order))


def synthetic_impulse_response(rng, rt60=0.4, seconds=0.5, direct=1.0):
    """Exponentially decaying noise tail after a unit direct path (simple room)."""
    length = max(int(seconds * RATE), 1)
    time = np.arange(length) / RATE
    tail = rng.normal(0.0, 1.0, length) * np.exp(-6.9078 * time / rt60)  # -60 dB at rt60
    tail[0] = 0.0
    tail *= 0.3 / max(np.sqrt(np.sum(tail ** 2)), 1e-12)
    response = tail
    response[0] = direct
    return response


def reverberate(audio, response):
    """Convolve and keep the original length so word timing stays comparable."""
    audio = np.asarray(audio, dtype=np.float64)
    if audio.size == 0:
        return audio.astype(np.float32)
    size = 1 << int(np.ceil(np.log2(audio.size + len(response))))
    wet = np.fft.irfft(np.fft.rfft(audio, size) * np.fft.rfft(response, size), size)[:audio.size]
    return wet.astype(np.float32)


def add_noise(audio, rng, level_dbfs=-60.0):
    noise = rng.normal(0.0, 10 ** (level_dbfs / 20), len(audio))
    return (np.asarray(audio, dtype=np.float64) + noise).astype(np.float32)


def overlap_mix(first, second, overlap_seconds):
    """`second` starts `overlap_seconds` before `first` ends (turn-taking with overlap)."""
    first, second = np.asarray(first, dtype=np.float64), np.asarray(second, dtype=np.float64)
    start = max(len(first) - int(round(overlap_seconds * RATE)), 0)
    mixed = np.zeros(max(len(first), start + len(second)))
    mixed[:len(first)] += first
    mixed[start:start + len(second)] += second
    return mixed.astype(np.float32)


def peak_safe(audio, ceiling=0.99):
    """Scale down (never up) so a synthetic mix cannot clip in int16."""
    audio = np.asarray(audio, dtype=np.float64)
    peak = np.max(np.abs(audio)) if audio.size else 0.0
    return (audio * (ceiling / peak if peak > ceiling else 1.0)).astype(np.float32)


def muffle(audio, rng, attenuation_db):
    """Low-pass ~3 kHz, attenuate and add a short synthetic room."""
    room = synthetic_impulse_response(rng, rt60=rng.uniform(0.3, 0.6))
    return reverberate(attenuate(lowpass(audio), attenuation_db), room)


def condition_clean(utterances, rng):
    (audio, text), = utterances
    return audio, text


def condition_muffled(utterances, rng):
    (audio, text), = utterances
    return peak_safe(add_noise(muffle(audio, rng, rng.uniform(15, 25)), rng)), text


def condition_muffled_two_speakers(utterances, rng):
    (first, first_text), (second, second_text) = utterances
    mixed = overlap_mix(muffle(first, rng, rng.uniform(15, 20)),
                        muffle(second, rng, rng.uniform(20, 25)), rng.uniform(0.5, 1.0))
    return peak_safe(add_noise(mixed, rng)), f"{first_text} {second_text}"


CONDITIONS = {
    "ren": (1, condition_clean),
    "dämpad": (1, condition_muffled),
    "dämpad_två_talare": (2, condition_muffled_two_speakers),
}
