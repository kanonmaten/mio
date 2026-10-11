import numpy as np
import pytest

from mio_transcription.preprocess import (MAX_GAIN_DB, RATE, TARGET_DBFS, float_to_pcm, frame_levels_db,
                                          highpass, normalization_gain_db, pcm_to_float, preprocess,
                                          preprocess_pcm)

TIME = np.arange(8 * RATE) / RATE


def tone(frequency, dbfs, gated=False):
    """Sine at an RMS level; `gated` adds 1 s pauses like turn-taking speech."""
    signal = np.sin(2 * np.pi * frequency * TIME) * np.sqrt(2) * 10 ** (dbfs / 20)
    return signal * (np.sin(2 * np.pi * 0.5 * TIME) > 0) if gated else signal


def rms_db(audio):
    return 20 * np.log10(np.sqrt(np.mean(np.asarray(audio, dtype=np.float64) ** 2)))


def test_dc_offset_is_removed_and_length_kept():
    audio = tone(1000, -30) + 0.2
    result = preprocess(audio)
    assert len(result) == len(audio)
    assert abs(float(np.mean(result))) < 1e-4


def test_highpass_removes_rumble_but_keeps_speech_band():
    rumble, voice = tone(30, -20), tone(1000, -20)
    assert rms_db(highpass(rumble)) < rms_db(rumble) - 15
    assert abs(rms_db(highpass(voice)) - rms_db(voice)) < 0.1


def test_highpass_is_zero_phase_so_word_times_do_not_move():
    audio = np.zeros(4 * RATE)
    audio[2 * RATE:2 * RATE + 1600] = np.sin(2 * np.pi * 500 * np.arange(1600) / RATE)
    envelope = np.abs(highpass(audio))
    assert abs(int(np.argmax(envelope)) - int(np.argmax(np.abs(audio)))) < 40  # < 2.5 ms


def test_quiet_muffled_speech_is_lifted_toward_target():
    result = preprocess(tone(1000, -30, gated=True))
    assert abs(frame_levels_db(result).max() - TARGET_DBFS) < 1.5


def test_gain_is_capped():
    audio = tone(1000, -60, gated=True)
    assert normalization_gain_db(audio) == MAX_GAIN_DB
    assert abs(frame_levels_db(preprocess(audio)).max() - (-60 + MAX_GAIN_DB)) < 1.5


def test_loud_speech_is_turned_down():
    assert normalization_gain_db(tone(1000, -8, gated=True)) < -10


def test_steady_noise_floor_and_silence_are_not_amplified():
    noise = np.random.default_rng(3).normal(0, 10 ** (-55 / 20), 8 * RATE)
    assert normalization_gain_db(noise) == 0.0
    assert rms_db(preprocess(noise)) <= rms_db(noise) + 0.1
    assert not np.any(preprocess(np.zeros(RATE)))
    assert preprocess(np.zeros(0)).size == 0


def test_loud_peaks_are_limited_without_clipping():
    square = np.sign(np.sin(2 * np.pi * 200 * TIME)) * 0.999
    spiky = tone(1000, -40, gated=True)
    spiky[RATE // 3] = 0.99
    for audio in (square, spiky):
        result = preprocess(audio)
        assert np.max(np.abs(result)) < 10 ** (-0.5 / 20) + 1e-6
        pcm = np.frombuffer(float_to_pcm(result), dtype="<i2")
        assert np.max(np.abs(pcm.astype(np.int32))) < 32767


def test_pcm_roundtrip_keeps_byte_length():
    pcm = float_to_pcm(tone(440, -30)[:12345])
    assert len(preprocess_pcm(pcm)) == len(pcm)
    assert np.allclose(pcm_to_float(pcm), tone(440, -30)[:12345], atol=1e-4)


@pytest.mark.parametrize("samples", [1, 319, 16_000])
def test_short_chunks_are_safe(samples):
    assert len(preprocess(np.ones(samples) * .1)) == samples
