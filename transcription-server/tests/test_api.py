import asyncio
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
import threading
import time
from uuid import uuid4
import wave

from fastapi.testclient import TestClient
import numpy as np
import pytest

from mio_transcription.app import create_app
from mio_transcription.core import Chunk, RequestError, decode_wave, normalize_words

TOKEN = "synthetic_test_token_" + "x" * 32


class Backend:
    model_id = "synthetic/pianissimo"
    revision = "a" * 40
    def __init__(self):
        self.calls = 0
        self.block = None
        self.words = [{"word": "Hej", "start": 0.1, "end": 0.5}]
    def load(self):
        pass
    def is_ready(self):
        return True
    def metadata(self):
        return {"model": self.model_id, "revision": self.revision, "backend": "synthetic"}
    def transcribe(self, pcm):
        self.calls += 1
        if self.block:
            self.block.wait(2)
        return normalize_words(self.words, len(pcm) // 2)


def audio(samples=16_000, rate=16_000, channels=1):
    buffer = BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setnchannels(channels); output.setsampwidth(2); output.setframerate(rate)
        output.writeframes(bytes(samples * channels * 2))
    return buffer.getvalue()


def headers(**changes):
    result = {"Authorization": f"Bearer {TOKEN}", "Content-Type": "audio/wav",
              "X-Mio-Session-ID": str(uuid4()), "X-Mio-Chunk-ID": str(uuid4()),
              "X-Mio-Sequence": "0", "X-Mio-Start-Sample": "0",
              "X-Mio-Core-Start": "0", "X-Mio-Core-End": "16000"}
    result.update(changes)
    return result


@pytest.fixture
def service():
    backend = Backend()
    exits = []
    with TestClient(create_app(backend, TOKEN, fatal_exit=exits.append)) as client:
        for _ in range(100):
            if client.get("/health", headers=headers()).status_code == 200:
                break
            time.sleep(.001)
        yield client, backend, exits


def test_health_reports_contract_without_audio(service):
    client, backend, _ = service
    response = client.get("/health", headers=headers())
    assert response.status_code == 200
    assert response.json()["metadata"]["revision"] == "a" * 40
    assert response.json()["encoding"] == "pcm_s16le_wav"
    assert response.headers["cache-control"] == "no-store"
    assert backend.calls == 0


@pytest.mark.parametrize("route,method", [("/health", "get"), ("/v1/transcribe", "post")])
def test_auth_before_inference(service, route, method):
    client, backend, _ = service
    assert getattr(client, method)(route).status_code == 401
    assert backend.calls == 0


def test_roundtrip_and_idempotent_retry(service):
    client, backend, _ = service
    h = headers(); body = audio()
    first = client.post("/v1/transcribe", headers=h, content=body)
    second = client.post("/v1/transcribe", headers=h, content=body)
    assert first.status_code == second.status_code == 200
    assert first.json() == second.json()
    assert first.json()["words"] == [{"text": "Hej", "start": .1, "end": .5}]
    assert first.json()["chunkID"] == h["X-Mio-Chunk-ID"]
    assert backend.calls == 1
    different = bytearray(body); different[-1] = 1
    assert client.post("/v1/transcribe", headers=h, content=bytes(different)).status_code == 409


@pytest.mark.parametrize("body", [b"not wave", audio(rate=8000), audio(channels=2), audio()[:-10]])
def test_invalid_audio(service, body):
    client, backend, _ = service
    assert client.post("/v1/transcribe", headers=headers(), content=body).status_code == 422
    assert backend.calls == 0


@pytest.mark.parametrize("changes", [{"X-Mio-Chunk-ID": "bad"}, {"X-Mio-Sequence": "-1"},
                                     {"X-Mio-Core-End": "99999999"}, {"X-Mio-Core-Start": "16000"}])
def test_invalid_metadata(service, changes):
    client, backend, _ = service
    assert client.post("/v1/transcribe", headers=headers(**changes), content=audio()).status_code == 400
    assert backend.calls == 0


def test_limits_and_content_type(service):
    client, backend, _ = service
    assert client.post("/v1/transcribe", headers=headers(), content=bytes(1_048_577)).status_code == 413
    assert client.post("/v1/transcribe", headers=headers(), content=audio(25 * 16000)).status_code == 422
    assert client.post("/v1/transcribe", headers=headers(**{"Content-Type": "application/json"}), content=b"{}").status_code == 415
    assert backend.calls == 0


@pytest.mark.parametrize("word", [{"word": "Hej", "start": -1, "end": .5},
                                  {"word": "Hej", "start": .1, "end": float("nan")},
                                  {"word": "Hej", "start": .1, "end": 10},
                                  {"word": "", "start": .1, "end": .5}])
def test_invalid_timestamps_are_errors_not_empty_success(service, word):
    client, backend, _ = service
    backend.words = [word]
    response = client.post("/v1/transcribe", headers=headers(), content=audio())
    assert response.status_code == 502
    assert response.json() == {"error": "invalid_model_result"}


def test_silence_is_valid_empty_success(service):
    client, backend, _ = service
    backend.words = []
    assert client.post("/v1/transcribe", headers=headers(), content=audio()).json()["words"] == []


def test_health_does_not_wait_for_gpu_and_overload_is_bounded(service):
    client, backend, _ = service
    backend.block = threading.Event()
    with ThreadPoolExecutor() as pool:
        future = pool.submit(client.post, "/v1/transcribe", headers=headers(), content=audio())
        for _ in range(100):
            if backend.calls:
                break
            time.sleep(.005)
        assert client.get("/health", headers=headers()).status_code == 200
        response = client.post("/v1/transcribe", headers=headers(), content=audio())
        assert response.status_code == 429
        assert response.headers["retry-after"] == "5"
        backend.block.set()
        assert future.result().status_code == 200


def test_loading_is_not_ready():
    backend = Backend(); unblock = threading.Event()
    backend.load = lambda: unblock.wait(2)
    with TestClient(create_app(backend, TOKEN)) as client:
        response = client.get("/health", headers=headers())
        assert response.status_code == 503
        assert response.json()["status"] == "loading"
        assert client.post("/v1/transcribe", headers=headers(), content=audio()).status_code == 503
        unblock.set()


def test_inference_deadline_requests_process_restart():
    backend = Backend(); backend.block = threading.Event(); exits = []
    with TestClient(create_app(backend, TOKEN, inference_timeout=.03, fatal_exit=exits.append)) as client:
        for _ in range(100):
            if client.get("/health", headers=headers()).status_code == 200:
                break
            time.sleep(.001)
        response = client.post("/v1/transcribe", headers=headers(), content=audio())
        assert response.status_code == 503
        assert exits == [1]
        assert client.get("/health", headers=headers()).json()["status"] == "failed"
        backend.block.set()


def test_no_open_documentation_or_unknown_routes(service):
    client, _, _ = service
    for route in ("/docs", "/openapi.json", "/v2/transcribe"):
        assert client.get(route).status_code == 404


def test_invalid_token_configuration_rejected():
    with pytest.raises(ValueError):
        create_app(Backend(), "short")


def test_retry_after_cache_expiration_runs_inference_again():
    backend = Backend()
    with TestClient(create_app(backend, TOKEN, cache_ttl=0, fatal_exit=lambda _: None)) as client:
        for _ in range(100):
            if client.get("/health", headers=headers()).status_code == 200:
                break
            time.sleep(.001)
        h = headers()
        assert client.post("/v1/transcribe", headers=h, content=audio()).status_code == 200
        assert client.post("/v1/transcribe", headers=h, content=audio()).status_code == 200
        assert backend.calls == 2


def test_frame_quantized_end_is_clipped_without_shifting_start():
    assert normalize_words([{"word": "Hej", "start": .2, "end": 1.08}], 16000) == [
        {"text": "Hej", "start": .2, "end": 1.0}]
    with pytest.raises(RequestError):
        normalize_words([{"word": "Hej", "start": 1.01, "end": 1.08}], 16000)


def test_oversized_serialized_result_is_rejected_before_retry_cache(service):
    client, backend, _ = service
    # Each word is independently valid. Together their JSON exceeds the iPhone cap.
    backend.words = [{"word": "å" * 200, "start": .1, "end": .5}] * 1500
    h = headers()
    first = client.post("/v1/transcribe", headers=h, content=audio())
    assert first.status_code == 502
    assert first.json() == {"error": "model_result_too_large"}
    backend.words = [{"word": "Hej", "start": .1, "end": .5}]
    second = client.post("/v1/transcribe", headers=h, content=audio())
    assert second.status_code == 200
    assert backend.calls == 2


def test_api_uses_backend_metadata_and_readiness_contract():
    backend = Backend()
    backend.metadata = lambda: {"model": "synthetic/adapter", "revision": "b" * 40, "backend": "synthetic"}
    backend.is_ready = lambda: False
    with TestClient(create_app(backend, TOKEN, fatal_exit=lambda _: None)) as client:
        time.sleep(.01)
        response = client.get("/health", headers=headers())
        assert response.status_code == 503
        assert response.json()["metadata"]["backend"] == "synthetic"
        assert client.post("/v1/transcribe", headers=headers(), content=audio()).status_code == 503
        assert backend.calls == 0


class Diarizer:
    """Fake speaker model: each owned region is one speaker, numbered per session state."""
    def __init__(self):
        self.calls, self.fail, self.load_error = [], False, None

    def load(self):
        if self.load_error:
            raise self.load_error

    def new_state(self):
        return {"seen": 0}

    def diarize(self, audio, state):
        self.calls.append(len(audio))
        if self.fail:
            raise RuntimeError("synthetic")
        return [(0.0, len(audio) / 16000, state["seen"] % 4)], {"seen": state["seen"] + 1}


@pytest.fixture
def start():
    clients = []

    def run(app):
        client = TestClient(app)
        client.__enter__()
        clients.append(client)
        for _ in range(400):
            body = client.get("/health", headers=headers()).json()
            if body["status"] == "ready" and body["speakerLabels"] != "loading":
                break
            time.sleep(.005)
        return client
    yield run
    for client in clients:
        client.__exit__(None, None, None)


def test_speaker_labels_are_additive_and_follow_the_session(start):
    backend, diarizer = Backend(), Diarizer()
    client = start(create_app(backend, TOKEN, fatal_exit=lambda _: None, diarizer=diarizer))
    health = client.get("/health", headers=headers()).json()
    assert health["speakerLabels"] == "ready" and health["preprocessing"] is True
    session = str(uuid4())
    first = client.post("/v1/transcribe", headers=headers(**{"X-Mio-Session-ID": session}), content=audio())
    second = client.post("/v1/transcribe", headers=headers(**{"X-Mio-Session-ID": session}), content=audio())
    other = client.post("/v1/transcribe", headers=headers(), content=audio())
    assert first.json()["words"] == [{"text": "Hej", "start": .1, "end": .5, "speaker": 1}]
    assert second.json()["words"][0]["speaker"] == 2
    assert other.json()["words"][0]["speaker"] == 1
    assert diarizer.calls == [16000] * 3
    # Ending the session drops its RAM state; a late chunk gets no invented numbering.
    assert client.delete(f"/v1/sessions/{session}").status_code == 401
    assert client.delete(f"/v1/sessions/{session.upper()}", headers=headers()).status_code == 204
    assert client.delete("/v1/sessions/bad", headers=headers()).status_code == 400
    late = client.post("/v1/transcribe", headers=headers(**{"X-Mio-Session-ID": session}), content=audio())
    assert late.json()["words"][0]["speaker"] is None
    assert len(diarizer.calls) == 3


def test_ending_a_session_also_drops_its_cached_text(start):
    backend = Backend()
    client = start(create_app(backend, TOKEN, fatal_exit=lambda _: None))
    h = headers()
    assert client.post("/v1/transcribe", headers=h, content=audio()).status_code == 200
    assert client.delete(f"/v1/sessions/{h['X-Mio-Session-ID']}", headers=headers()).status_code == 204
    assert client.post("/v1/transcribe", headers=h, content=audio()).status_code == 200
    assert backend.calls == 2


def test_speaker_failure_never_fails_transcription(start):
    backend, diarizer, exits = Backend(), Diarizer(), []
    diarizer.fail = True
    client = start(create_app(backend, TOKEN, fatal_exit=exits.append, diarizer=diarizer))
    response = client.post("/v1/transcribe", headers=headers(), content=audio())
    assert response.status_code == 200
    assert response.json()["words"] == [{"text": "Hej", "start": .1, "end": .5, "speaker": None}]
    assert exits == []


def test_unloadable_speaker_model_keeps_v1_words_unchanged(start):
    backend, diarizer = Backend(), Diarizer()
    diarizer.load_error = OSError("missing")
    client = start(create_app(backend, TOKEN, fatal_exit=lambda _: None, diarizer=diarizer))
    assert client.get("/health", headers=headers()).json()["speakerLabels"] == "off"
    response = client.post("/v1/transcribe", headers=headers(), content=audio())
    assert response.json()["words"] == [{"text": "Hej", "start": .1, "end": .5}]


def test_no_speaker_model_means_unchanged_v1_words(service):
    client, _, _ = service
    assert client.get("/health", headers=headers()).json()["speakerLabels"] == "off"
    assert client.post("/v1/transcribe", headers=headers(), content=audio()).json()["words"] == [
        {"text": "Hej", "start": .1, "end": .5}]


def test_speaker_state_expires_after_idle_ttl(start):
    backend, diarizer, now = Backend(), Diarizer(), [0.0]
    client = start(create_app(backend, TOKEN, fatal_exit=lambda _: None, diarizer=diarizer,
                              speaker_clock=lambda: now[0]))
    session = {"X-Mio-Session-ID": str(uuid4())}
    assert client.post("/v1/transcribe", headers=headers(**session), content=audio()).json()["words"][0]["speaker"] == 1
    now[0] = 600
    again = client.post("/v1/transcribe", headers=headers(**session), content=audio())
    assert again.json()["words"][0]["speaker"] == 1  # fresh state after 10 minutes idle


def test_oversized_result_drops_speakers_before_failing(start):
    backend, diarizer = Backend(), Diarizer()
    # Fits the 262144-byte cap without speaker fields, but not with them.
    backend.words = [{"word": "å" * 67, "start": .1, "end": .5}] * 1500
    client = start(create_app(backend, TOKEN, fatal_exit=lambda _: None, diarizer=diarizer))
    response = client.post("/v1/transcribe", headers=headers(), content=audio())
    assert response.status_code == 200
    assert "speaker" not in response.json()["words"][0]


class RecordingBackend(Backend):
    def transcribe(self, pcm):
        self.pcm = pcm
        return super().transcribe(pcm)


def offset_audio(samples=16_000):
    buffer = BytesIO()
    with wave.open(buffer, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        output.writeframes(np.full(samples, 3000, dtype="<i2").tobytes())
    return buffer.getvalue()


@pytest.mark.parametrize("enabled", [True, False])
def test_preprocessing_reaches_the_model_only_when_enabled(start, enabled):
    backend = RecordingBackend()
    client = start(create_app(backend, TOKEN, fatal_exit=lambda _: None, preprocessing=enabled))
    body = offset_audio()
    assert client.post("/v1/transcribe", headers=headers(), content=body).status_code == 200
    received = np.frombuffer(backend.pcm, dtype="<i2")
    assert len(received) == 16_000
    if enabled:
        assert abs(received.mean()) < 5  # DC offset removed before the model
    else:
        assert backend.pcm == body[44:]
    assert client.get("/health", headers=headers()).json()["preprocessing"] is enabled


@pytest.mark.parametrize("seconds,core", [(8 + 2, (16_000, 144_000)), (22 + 2, (16_000, 368_000)),
                                          (22, (0, 352_000))])
def test_pause_cut_chunk_lengths_fit_the_contract(service, seconds, core):
    client, _, _ = service
    response = client.post("/v1/transcribe", content=audio(seconds * 16_000), headers=headers(
        **{"X-Mio-Core-Start": str(core[0]), "X-Mio-Core-End": str(core[1])}))
    assert response.status_code == 200
    assert len(audio(24 * 16_000)) <= 1_048_576


def test_one_sample_over_24_seconds_is_rejected(service):
    client, backend, _ = service
    assert client.post("/v1/transcribe", headers=headers(), content=audio(24 * 16_000 + 1)).status_code == 422
    assert backend.calls == 0


def test_invalid_feature_flag_is_a_configuration_error(monkeypatch):
    monkeypatch.setenv("MIO_PREPROCESS", "kanske")
    with pytest.raises(ValueError):
        create_app(Backend(), TOKEN)
