"""Model-independent level cleanup before ASR. Works on RAM buffers only.

Deliberately no denoiser or spectral gating: denoising front-ends often raise the
word error rate of modern end-to-end ASR (arXiv 2512.17562). Every step here is
linear or a soft peak limiter, and zero-phase so word timestamps never shift.
"""
import numpy as np

RATE = 16_000
HIGHPASS_HZ = 80.0
TARGET_DBFS = -23.0          # RMS of the active (speech-like) frames after gain
MAX_GAIN_DB = 20.0           # never lift a chunk by more than this
MIN_GAIN_DB = -20.0
FRAME = 320                  # 20 ms analysis frames
ABSOLUTE_GATE_DBFS = -65.0   # below this a frame is treated as silence
ACTIVE_MARGIN_DB = 6.0       # active frames must exceed the chunk's noise floor by this
MIN_ACTIVE_FRAMES = 15       # 0.3 s; fewer means "noise only": never amplify
LIMIT_THRESHOLD = 10 ** (-3 / 20)
LIMIT_CEILING = 10 ** (-0.5 / 20)
_EPS = 1e-12


def pcm_to_float(pcm):
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0


def float_to_pcm(audio):
    return np.clip(np.round(np.asarray(audio, dtype=np.float64) * 32767.0), -32768, 32767).astype("<i2").tobytes()


def _db(value):
    return 20.0 * np.log10(np.maximum(value, _EPS))


def zero_phase_filter(audio, gain_for_frequency):
    """Apply a real, non-negative magnitude response through a padded FFT.

    Zero phase means no group delay, so the API's word timing anchor is preserved.
    Zero padding to at least twice the length keeps circular wrap-around out of
    the returned span.
    """
    audio = np.asarray(audio, dtype=np.float64)
    if audio.size == 0:
        return audio.astype(np.float32)
    size = 1 << int(np.ceil(np.log2(max(2 * audio.size, 2))))
    spectrum = np.fft.rfft(audio, n=size)
    frequencies = np.fft.rfftfreq(size, 1.0 / RATE)
    filtered = np.fft.irfft(spectrum * gain_for_frequency(frequencies), n=size)[:audio.size]
    return filtered.astype(np.float32)


def butterworth_highpass_gain(frequencies, cutoff=HIGHPASS_HZ, order=2):
    """Magnitude of an order-N Butterworth high-pass (12 dB/octave for N=2)."""
    frequencies = np.asarray(frequencies, dtype=np.float64)
    gain = np.zeros_like(frequencies)
    positive = frequencies > 0
    gain[positive] = 1.0 / np.sqrt(1.0 + (cutoff / frequencies[positive]) ** (2 * order))
    return gain


def butterworth_lowpass_gain(frequencies, cutoff, order=4):
    frequencies = np.asarray(frequencies, dtype=np.float64)
    return 1.0 / np.sqrt(1.0 + (frequencies / cutoff) ** (2 * order))


def highpass(audio, cutoff=HIGHPASS_HZ):
    return zero_phase_filter(audio, lambda f: butterworth_highpass_gain(f, cutoff))


def frame_levels_db(audio):
    count = len(audio) // FRAME
    if count == 0:
        return np.zeros(0)
    frames = np.asarray(audio[:count * FRAME], dtype=np.float64).reshape(count, FRAME)
    return _db(np.sqrt(np.mean(frames ** 2, axis=1)))


def normalization_gain_db(audio):
    """Gain toward TARGET_DBFS measured on speech-like frames only.

    The noise floor is the 10th percentile frame level. A chunk with too few
    frames clearly above it (silence, steady hum or hiss) is never amplified,
    so the model does not receive a lifted noise floor as pseudo-speech.
    """
    levels = frame_levels_db(audio)
    if levels.size == 0:
        return 0.0
    floor = np.percentile(levels, 10)
    active = levels > max(ABSOLUTE_GATE_DBFS, floor + ACTIVE_MARGIN_DB)
    if np.count_nonzero(active) < MIN_ACTIVE_FRAMES:
        return 0.0
    frames = np.asarray(audio[:levels.size * FRAME], dtype=np.float64).reshape(levels.size, FRAME)[active]
    active_db = float(_db(np.sqrt(np.mean(frames ** 2))))
    return float(np.clip(TARGET_DBFS - active_db, MIN_GAIN_DB, MAX_GAIN_DB))


def soft_limit(audio):
    """Sample-wise soft knee above -3 dBFS; output magnitude stays below -0.5 dBFS.

    Unity slope at the threshold, so normal speech is untouched and only rare
    peaks are rounded off instead of hard-clipped in the int16 conversion.
    """
    audio = np.asarray(audio, dtype=np.float64)
    magnitude = np.abs(audio)
    over = magnitude > LIMIT_THRESHOLD
    span = LIMIT_CEILING - LIMIT_THRESHOLD
    limited = np.where(over, LIMIT_THRESHOLD + span * np.tanh((magnitude - LIMIT_THRESHOLD) / span), magnitude)
    return (np.sign(audio) * limited).astype(np.float32)


def preprocess(audio):
    """DC removal, 80 Hz zero-phase high-pass, level normalization, soft limit.

    Input and output are float32 in [-1, 1] at 16 kHz with identical length.
    """
    audio = np.asarray(audio, dtype=np.float64)
    if audio.size == 0:
        return audio.astype(np.float32)
    audio = audio - audio.mean()
    audio = highpass(audio).astype(np.float64)
    gain = 10 ** (normalization_gain_db(audio) / 20)
    return soft_limit(audio * gain)


def preprocess_pcm(pcm):
    return float_to_pcm(preprocess(pcm_to_float(pcm)))
