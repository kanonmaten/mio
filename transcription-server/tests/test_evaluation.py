import importlib.util
from pathlib import Path
import wave

import numpy as np
import pytest

from mio_transcription.evaluation import (CONDITIONS, add_noise, attenuate, edit_distance, lowpass,
                                          normalize_text, overlap_mix, peak_safe, reverberate, rms_dbfs,
                                          synthetic_impulse_response, word_error_rate)
from mio_transcription.preprocess import RATE, float_to_pcm

TIME = np.arange(2 * RATE) / RATE


def sine(frequency, amplitude=0.5):
    return (amplitude * np.sin(2 * np.pi * frequency * TIME)).astype(np.float32)


def test_swedish_normalization():
    assert normalize_text("Hej, Åsa! Är du där? (Ja.)") == ["hej", "åsa", "är", "du", "där", "ja"]
    assert normalize_text("e-post kl. 14:30") == ["e", "post", "kl", "14", "30"]
    assert normalize_text("Århus") == ["århus"]  # decomposed å is composed first


def test_edit_distance_counts_each_error_type():
    assert edit_distance("a b c".split(), "a b c".split()) == 0
    assert edit_distance("a b c".split(), "a x c".split()) == 1
    assert edit_distance("a b c".split(), "a c".split()) == 1
    assert edit_distance("a b c".split(), "a b b c".split()) == 1
    assert edit_distance([], "a b".split()) == 2
    assert edit_distance("a b".split(), []) == 2


def test_corpus_wer_uses_total_reference_words():
    assert word_error_rate(["Hej på dig.", "Två ord"], ["hej på dig", "två"]) == pytest.approx(1 / 5)
    assert word_error_rate(["Ett"], ["ett två tre"]) == 2.0
    with pytest.raises(ValueError):
        word_error_rate(["a"], [])
    with pytest.raises(ValueError):
        word_error_rate(["..."], ["a"])


def test_lowpass_muffles_high_frequencies():
    assert rms_dbfs(lowpass(sine(6000))) < rms_dbfs(sine(6000)) - 20
    assert abs(rms_dbfs(lowpass(sine(500))) - rms_dbfs(sine(500))) < 0.1


def test_attenuation_is_exact():
    assert rms_dbfs(attenuate(sine(500), 20)) == pytest.approx(rms_dbfs(sine(500)) - 20, abs=1e-3)


def test_reverb_keeps_length_direct_path_and_decays():
    response = synthetic_impulse_response(np.random.default_rng(1), rt60=0.4)
    assert response[0] == 1.0
    assert np.mean(np.abs(response[1:800])) > 10 * np.mean(np.abs(response[-800:]))
    impulse = np.zeros(RATE)
    impulse[100] = 1
    wet = reverberate(impulse, response)
    assert len(wet) == RATE and np.argmax(np.abs(wet)) == 100
    assert np.array_equal(synthetic_impulse_response(np.random.default_rng(1), rt60=0.4), response)


def test_noise_level():
    noisy = add_noise(np.zeros(10 * RATE), np.random.default_rng(2), -60)
    assert rms_dbfs(noisy) == pytest.approx(-60, abs=0.2)


def test_overlap_mix_places_second_speaker_before_first_ends():
    first, second = np.ones(RATE), np.full(RATE, 2.0)
    mixed = overlap_mix(first, second, 0.25)
    assert len(mixed) == 2 * RATE - RATE // 4
    assert mixed[0] == 1 and mixed[RATE - 1] == 3 and mixed[-1] == 2


def test_peak_safe_never_amplifies():
    assert np.max(np.abs(peak_safe(np.array([2.0, -4.0])))) == pytest.approx(0.99)
    assert np.array_equal(peak_safe(np.array([0.1, -0.2])), np.array([0.1, -0.2], dtype=np.float32))


@pytest.mark.parametrize("name", list(CONDITIONS))
def test_conditions_are_deterministic_and_unclipped(name):
    speakers, make = CONDITIONS[name]
    utterances = [(sine(300 + 100 * i), f"mening {i}") for i in range(speakers)]
    audio, reference = make(utterances, np.random.default_rng(7))
    again, _ = make(utterances, np.random.default_rng(7))
    assert np.array_equal(audio, again)
    assert np.max(np.abs(audio)) <= 0.99
    assert reference == " ".join(text for _, text in utterances)
    if name != "ren":
        assert rms_dbfs(audio) < rms_dbfs(utterances[0][0]) - 10


def load_script():
    path = Path(__file__).resolve().parents[1] / "scripts/measure_wer.py"
    spec = importlib.util.spec_from_file_location("measure_wer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_wave(path, audio, rate=RATE):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(float_to_pcm(audio))


def test_script_reads_pairs_and_fleurs_and_skips_wrong_format(tmp_path):
    # Synthetic tones in pytest's temporary folder only; no speech, nothing kept.
    script = load_script()
    write_wave(tmp_path / "a.wav", sine(300))
    (tmp_path / "a.txt").write_text("Hej där.")
    write_wave(tmp_path / "b.wav", sine(300), rate=8000)
    (tmp_path / "b.txt").write_text("Fel takt")
    write_wave(tmp_path / "c.wav", sine(300))  # no reference text: ignored
    items, skipped = script.load(tmp_path, 10)
    assert [(group, text) for group, _, text in items] == [("a", "Hej där.")] and skipped == 1

    fleurs = tmp_path / "fleurs"
    (fleurs / "audio/test").mkdir(parents=True)
    for name in ("x.wav", "y.wav"):
        write_wave(fleurs / "audio/test" / name, sine(300))
    (fleurs / "test.tsv").write_text("1\tx.wav\tFörsta meningen.\tförsta meningen\n"
                                     "2\ty.wav\tAndra meningen.\tandra meningen\n")
    items, _ = script.load(fleurs, 10)
    assert [text for _, _, text in items] == ["Första meningen.", "Andra meningen."]
    mixes = list(script.build("dämpad_två_talare", items, np.random.default_rng(1)))
    assert [reference for _, reference in mixes] == ["Första meningen. Andra meningen.",
                                                     "Andra meningen. Första meningen."]
    assert all(len(audio) <= 24 * RATE for audio, _ in mixes)
