from dataclasses import dataclass
from hashlib import sha256
from io import BytesIO
import math
import re
from uuid import UUID
import wave

RATE = 16_000
MAX_BYTES = 1_048_576
MAX_RESPONSE_BYTES = 262_144
MAX_SAMPLES = RATE * 24


class RequestError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


@dataclass(frozen=True)
class Chunk:
    session_id: str
    chunk_id: str
    sequence: int
    start_sample: int
    core_start: int
    core_end: int

    @classmethod
    def from_headers(cls, headers):
        try:
            values = [str(UUID(headers[f"x-mio-{key}-id"])) for key in ("session", "chunk")]
            numbers = []
            for key in ("sequence", "start-sample", "core-start", "core-end"):
                value = headers[f"x-mio-{key}"]
                if not re.fullmatch(r"[0-9]{1,15}", value):
                    raise ValueError()
                numbers.append(int(value))
            chunk = cls(*values, *numbers)
            if not 0 <= chunk.core_start < chunk.core_end <= MAX_SAMPLES:
                raise ValueError()
            return chunk
        except (KeyError, ValueError, TypeError):
            raise RequestError(400, "invalid_chunk") from None

    def fingerprint(self, body):
        return sha256(repr(self).encode() + body).hexdigest()


def decode_wave(body, chunk):
    if len(body) > MAX_BYTES:
        raise RequestError(413, "audio_too_large")
    try:
        with wave.open(BytesIO(body), "rb") as audio:
            frames = audio.getnframes()
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, RATE, "NONE"):
                raise ValueError()
            if not chunk.core_end <= frames <= MAX_SAMPLES:
                raise ValueError()
            pcm = audio.readframes(frames)
            if len(pcm) != frames * 2:
                raise ValueError()
            return pcm
    except (wave.Error, EOFError, ValueError):
        raise RequestError(422, "invalid_audio") from None


def normalize_words(words, samples):
    result = []
    previous = 0.0
    for item in words:
        try:
            start, end = float(item["start"]), float(item["end"])
            text = item["word"].strip()
            if (not math.isfinite(start) or not math.isfinite(end)
                    or not 0 <= start <= end <= samples / RATE + 0.1
                    or start > samples / RATE or start < previous or not text or len(text.encode()) > 400):
                raise ValueError()
            result.append({"text": text, "start": start, "end": min(end, samples / RATE)})
            previous = start
            if len(result) > 1500:
                raise ValueError()
        except (KeyError, TypeError, ValueError, AttributeError):
            raise RequestError(502, "invalid_model_result") from None
    return result


def validate_backend_words(words, samples):
    """The API consumes normalized words; backend-specific keys stay in the adapter."""
    if not isinstance(words, list) or len(words) > 1500:
        raise RequestError(502, "invalid_model_result")
    previous = 0.0
    for word in words:
        try:
            text, start, end = word["text"], word["start"], word["end"]
            if (not isinstance(text, str) or not text.strip() or len(text.encode()) > 400
                    or isinstance(start, bool) or isinstance(end, bool)
                    or not math.isfinite(start) or not math.isfinite(end)
                    or not previous <= start <= end <= samples / RATE + .02):
                raise ValueError()
            previous = start
        except (KeyError, TypeError, ValueError, AttributeError):
            raise RequestError(502, "invalid_model_result") from None
    return words


def validate_backend_metadata(metadata):
    if (not isinstance(metadata, dict) or set(metadata) != {"model", "revision", "backend"}
            or any(not isinstance(value, str) or not value or len(value.encode()) > 200
                   or any(ord(character) < 32 for character in value) for value in metadata.values())):
        raise RequestError(502, "invalid_model_metadata")
    return metadata
