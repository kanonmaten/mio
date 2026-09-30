import asyncio
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
import threading
import time
from uuid import uuid4
import wave

from fastapi.testclient import TestClient
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
    def transcribe(self, pcm):
        self.calls += 1
        if self.block:
            self.block.wait(2)
        return self.words


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
