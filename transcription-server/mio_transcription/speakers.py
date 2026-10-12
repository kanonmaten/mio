"""Optional speaker labels per word. Never allowed to fail a transcription.

Per-session diarizer state (for Streaming Sortformer: its speaker cache of
frame embeddings) lives only in this process's RAM. It is dropped when the
client ends the session, after an idle TTL, on eviction and at shutdown.
Nothing here is written to disk or logged beyond exception type names.
"""
import logging
import math
import os
import re
import threading
import time
from typing import Protocol

import numpy as np

from .core import RATE

log = logging.getLogger("mio_transcription")
MAX_SPEAKERS = 4
DEFAULT_DIARIZATION_MODEL = "nvidia/diar_streaming_sortformer_4spk-v2"


class Diarizer(Protocol):
    """float32 16 kHz mono in; (start, end, speaker 0..3) seconds relative to that audio out."""
    def load(self) -> None: ...
    def new_state(self) -> object: ...
    def diarize(self, audio: np.ndarray, state: object) -> tuple[list[tuple[float, float, int]], object]: ...


class SpeakerSessions:
    """RAM-only per-session diarizer state with idle TTL and an LRU bound.

    An ended session leaves an ID-only tombstone for the TTL, so a late retry
    cannot silently start a new speaker numbering under the same session.
    """

    def __init__(self, ttl=600, max_sessions=4, clock=time.monotonic):
        self.ttl, self.max_sessions, self.clock = ttl, max_sessions, clock
        self._states = {}
        self._ended = {}
        self._lock = threading.Lock()

    def checkout(self, session_id, factory):
        """Return the session's state (new if unknown), or None when it was ended."""
        with self._lock:
            self._expire_locked()
            if session_id in self._ended:
                return None
            entry = self._states.pop(session_id, None)
        return entry[1] if entry else factory()

    def checkin(self, session_id, state):
        with self._lock:
            if session_id in self._ended:
                return
            self._states[session_id] = (self.clock(), state)
            while len(self._states) > self.max_sessions:
                del self._states[next(iter(self._states))]

    def drop(self, session_id):
        with self._lock:
            self._states.pop(session_id, None)

    def end(self, session_id):
        with self._lock:
            self._states.pop(session_id, None)
            self._ended[session_id] = self.clock()

    def expire(self):
        with self._lock:
            self._expire_locked()

    def _expire_locked(self):
        now = self.clock()
        for table in (self._states, self._ended):
            for key in [key for key, value in table.items()
                        if now - (value[0] if isinstance(value, tuple) else value) >= self.ttl]:
                del table[key]

    def clear(self):
        with self._lock:
            self._states.clear()
            self._ended.clear()

    def __len__(self):
        with self._lock:
            return len(self._states)


def valid_segments(segments, duration):
    if not isinstance(segments, list) or len(segments) > 10_000:
        raise ValueError()
    result = []
    for start, end, speaker in segments:
        start, end = float(start), float(end)
        if (not math.isfinite(start) or not math.isfinite(end) or isinstance(speaker, bool)
                or int(speaker) != speaker or not 0 <= int(speaker) < MAX_SPEAKERS
                or not 0 <= start <= end <= duration + 0.5):
            raise ValueError()
        result.append((start, end, int(speaker)))
    return result


def assign_speakers(words, segments, offset, core_start, core_end):
    """Label words by the speaker with the largest time overlap.

    `segments` are relative to the owned core region, which begins `offset`
    seconds into the WAV. Words whose midpoint falls outside [core_start,
    core_end) get None: the client discards those context words anyway, and the
    diarizer state has only seen the owned region.
    """
    result = []
    for word in words:
        start, end = word["start"], word["end"]
        middle = (start + end) / 2
        speaker = None
        if core_start <= middle < core_end:
            overlap = [0.0] * MAX_SPEAKERS
            for seg_start, seg_end, index in segments:
                seg_start, seg_end = seg_start + offset, seg_end + offset
                if end > start:
                    overlap[index] += max(0.0, min(end, seg_end) - max(start, seg_start))
                elif seg_start <= middle < seg_end:
                    overlap[index] += 1.0
            best = max(range(MAX_SPEAKERS), key=lambda index: overlap[index])
            speaker = best + 1 if overlap[best] > 0 else None
        result.append({**word, "speaker": speaker})
    return result


def strip_speakers(words):
    return [{key: value for key, value in word.items() if key != "speaker"} for word in words]


class SpeakerLabeler:
    """Owns diarizer readiness and session state; `label` never raises."""

    def __init__(self, diarizer, ttl=600, max_sessions=4, clock=time.monotonic):
        self.diarizer = diarizer
        self.sessions = SpeakerSessions(ttl, max_sessions, clock)
        self.status = "loading"

    def load(self):
        try:
            self.diarizer.load()
            self.status = "ready"
            log.warning("Talarmärkning aktiv.")
        except Exception as error:  # the diarizer is optional; transcription continues
            self.status = "off"
            log.warning("Talarmärkning avstängd: modellen kunde inte laddas (%s).", type(error).__name__)

    def label(self, chunk, audio, words):
        if self.status != "ready":
            return words
        try:
            state = self.sessions.checkout(chunk.session_id, self.diarizer.new_state)
            if state is None:
                return [{**word, "speaker": None} for word in words]
            # Only the owned region reaches the streaming state, so overlapping
            # context seconds are not fed twice into the speaker cache.
            core = np.asarray(audio[chunk.core_start:chunk.core_end], dtype=np.float32)
            segments, state = self.diarizer.diarize(core, state)
            segments = valid_segments(segments, len(core) / RATE)
            self.sessions.checkin(chunk.session_id, state)
        except Exception as error:
            self.sessions.drop(chunk.session_id)
            log.warning("Talarmärkning misslyckades för en ljuddel (%s); orden saknar talare.",
                        type(error).__name__)
            return [{**word, "speaker": None} for word in words]
        return assign_speakers(words, segments, chunk.core_start / RATE,
                               chunk.core_start / RATE, chunk.core_end / RATE)


def segments_from_probabilities(probabilities, frame_seconds, threshold=0.5):
    """Turn a (frames, speakers) activity matrix into (start, end, speaker) runs."""
    probabilities = np.asarray(probabilities, dtype=np.float64)
    segments = []
    if probabilities.ndim != 2 or probabilities.shape[0] == 0:
        return segments
    active = probabilities > threshold
    for speaker in range(min(active.shape[1], MAX_SPEAKERS)):
        column = np.concatenate(([False], active[:, speaker], [False]))
        edges = np.flatnonzero(column[1:] != column[:-1])
        for start, end in zip(edges[::2], edges[1::2]):
            segments.append((start * frame_seconds, end * frame_seconds, speaker))
    return sorted(segments)


class SortformerDiarizer:
    """NVIDIA Streaming Sortformer 4spk-v2 through NeMo, on CUDA.

    UNVERIFIED: written against NeMo 2.7.0's SortformerEncLabelModel source
    (process_signal, streaming_feat_loader, forward_streaming_step) without a
    GPU run; NeMo 3.0.0 keeps these signatures unchanged. Any failure only turns
    speaker labels off.
    """
    FRAME_SECONDS = 0.08  # 10 ms mel hop x 8 subsampling, per the model card

    def __init__(self):
        self.model_id = os.getenv("MIO_DIARIZATION_MODEL_ID", DEFAULT_DIARIZATION_MODEL)
        self.revision = os.getenv("MIO_DIARIZATION_REVISION", "")
        if not re.fullmatch(r"[a-f0-9]{40}", self.revision):
            raise ValueError("MIO_DIARIZATION_REVISION must be a commit SHA")
        self.model = None

    def load(self):
        import torch
        from huggingface_hub import snapshot_download
        from nemo.collections.asr.models import SortformerEncLabelModel
        from pathlib import Path
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA required")
        folder = Path(snapshot_download(repo_id=self.model_id, revision=self.revision,
                                        allow_patterns=["*.nemo"]))
        files = list(folder.glob("*.nemo"))
        if len(files) != 1:
            raise RuntimeError("Expected one NeMo checkpoint")
        model = SortformerEncLabelModel.restore_from(str(files[0]), map_location="cuda", strict=False).eval()
        modules = model.sortformer_modules
        # Model card "very high latency" setting: a whole 8-24 s request fits in
        # one 27.2 s streaming step, with the speaker cache carrying identities.
        modules.chunk_len, modules.chunk_right_context = 340, 40
        modules.fifo_len, modules.spkcache_update_period, modules.spkcache_len = 40, 300, 188
        modules._check_streaming_parameters()
        model.streaming_mode = True  # skip per-request peak scaling; levels come from preprocessing
        self.model = model
        # Warm-up with digital silence and a throwaway state; no real audio.
        self.diarize(np.zeros(2 * RATE, dtype=np.float32), self.new_state())

    def new_state(self):
        modules = self.model.sortformer_modules
        return modules.init_streaming_state(batch_size=1, async_streaming=self.model.async_streaming,
                                            device=self.model.device)

    def diarize(self, audio, state):
        import torch
        model, modules = self.model, self.model.sortformer_modules
        with torch.inference_mode():
            signal = torch.from_numpy(np.ascontiguousarray(audio, dtype=np.float32)).unsqueeze(0).to(model.device)
            length = torch.tensor([signal.shape[1]], device=model.device)
            features, feature_lengths = model.process_signal(audio_signal=signal, audio_signal_length=length)
            features = features[:, :, :feature_lengths.max()]
            predictions = torch.zeros((1, 0, modules.n_spk), device=model.device)
            offset = torch.zeros((1,), dtype=torch.long, device=model.device)
            for _, part, part_lengths, left, right in modules.streaming_feat_loader(
                    feat_seq=features, feat_seq_length=feature_lengths, feat_seq_offset=offset):
                state, predictions = model.forward_streaming_step(
                    processed_signal=part, processed_signal_length=part_lengths, streaming_state=state,
                    total_preds=predictions, left_offset=left, right_offset=right)
            probabilities = predictions[0].float().cpu().numpy()
        return segments_from_probabilities(probabilities, self.FRAME_SECONDS), state
