import asyncio
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
import hmac
from importlib.metadata import PackageNotFoundError, version as package_version
import json
import logging
import os
import re
import time
from uuid import UUID

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from .core import (Chunk, MAX_BYTES, MAX_RESPONSE_BYTES, RATE, RequestError, decode_wave,
                   validate_backend_words, validate_backend_metadata)
from .preprocess import float_to_pcm, pcm_to_float, preprocess
from .speakers import SpeakerLabeler, strip_speakers
from .vocabulary import PhoneVocabulary, VocabularyFull, normalize_phrase

MAX_VOCABULARY_BODY = 1_024

log = logging.getLogger("mio_transcription")


def server_version():
    # One version for the whole repo (2026-11-21): uv sync installs this package, so /health
    # reports the version in pyproject.toml, which the verifier keeps equal to VERSION.
    try:
        return package_version("mio-transcription")
    except PackageNotFoundError:
        return "okänd"



def env_flag(name, default):
    value = os.environ.get(name, "").strip().lower()
    if not value:
        return default
    if value in ("1", "true", "on", "ja"):
        return True
    if value in ("0", "false", "off", "nej"):
        return False
    raise ValueError(f"{name} must be 1 or 0")


def default_diarizer():
    """Sortformer when enabled and configured; otherwise None with one log line."""
    if not env_flag("MIO_SPEAKER_LABELS", True):
        log.warning("Talarmärkning avstängd (MIO_SPEAKER_LABELS=0).")
        return None
    from .speakers import SortformerDiarizer
    try:
        return SortformerDiarizer()
    except ValueError:
        log.warning("Talarmärkning avstängd: MIO_DIARIZATION_REVISION saknas eller är ogiltig. Kör install.sh.")
        return None


def create_app(backend=None, token=None, inference_timeout=45, fatal_exit=os._exit, cache_ttl=90,
               diarizer=None, preprocessing=None, speaker_ttl=600, speaker_clock=time.monotonic,
               vocabulary=None, reload_timeout=15, reload_limit=300):
    token = token if token is not None else os.environ.get("MIO_TRANSCRIPTION_TOKEN", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        raise ValueError("Set a 32-256 character MIO_TRANSCRIPTION_TOKEN")
    preprocessing = env_flag("MIO_PREPROCESS", True) if preprocessing is None else preprocessing
    if backend is None:
        from .backend import Pianissimo
        backend = Pianissimo()
        if diarizer is None:
            diarizer = default_diarizer()
    vocabulary = vocabulary if vocabulary is not None else PhoneVocabulary()
    labeler = SpeakerLabeler(diarizer, ttl=speaker_ttl, clock=speaker_clock) if diarizer else None
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="inference")
    # Speaker model loading must never delay or block transcription readiness.
    side_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="speaker-load")
    state = {"status": "loading", "busy": False, "preprocess_warned": False}
    cache = OrderedDict()
    jobs = set()

    def prune_cache(now):
        for key in list(cache):
            if now - cache[key][0] >= cache_ttl:
                del cache[key]

    async def load():
        try:
            await asyncio.wait_for(asyncio.get_running_loop().run_in_executor(executor, backend.load), 300)
            state["status"] = "ready" if backend.is_ready() else "loading"
            if labeler:
                side_executor.submit(labeler.load)
        except asyncio.CancelledError:
            raise
        except Exception:
            state["status"] = "failed"
            # A stuck/native CUDA operation cannot safely be reused after a timeout.
            # systemd restarts the complete process. Never print exception payloads.
            fatal_exit(1)

    async def expire_cache():
        while True:
            await asyncio.sleep(1)
            prune_cache(time.monotonic())
            if labeler:
                labeler.sessions.expire()

    @asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(load())
        cleanup = asyncio.create_task(expire_cache())
        yield
        task.cancel()
        cleanup.cancel()
        cache.clear()
        if labeler:
            labeler.sessions.clear()
        for job in jobs:
            job.cancel()
        executor.shutdown(wait=False, cancel_futures=True)
        side_executor.shutdown(wait=False, cancel_futures=True)

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)

    @app.exception_handler(RequestError)
    async def error_handler(request, error):
        headers = {"Cache-Control": "no-store"}
        if error.status in (429, 503):
            headers["Retry-After"] = "5"
        return JSONResponse({"error": error.code}, status_code=error.status, headers=headers)

    def authenticate(request):
        supplied = request.headers.get("authorization", "")
        if len(supplied) > 263 or not hmac.compare_digest(supplied.encode(), f"Bearer {token}".encode()):
            raise RequestError(401, "unauthorized")

    def metadata():
        return validate_backend_metadata(backend.metadata())

    def ready():
        return state["status"] == "ready" and backend.is_ready()

    def vocabulary_size():
        # Additive and optional: a backend without own-word support reports none.
        try:
            size = getattr(backend, "vocabulary_size", lambda: 0)()
        except Exception:
            return 0
        return size if isinstance(size, int) and not isinstance(size, bool) and 0 <= size <= 500 else 0

    def precision():
        # Additive and optional: a backend without a precision setting computes in fp32.
        value = getattr(backend, "precision", "fp32")
        return value if value in ("fp32", "fp16") else "fp32"

    def json_response(body):
        return Response(body, media_type="application/json", headers={"Cache-Control": "no-store"})

    @app.get("/health")
    async def health(request: Request):
        authenticate(request)
        return JSONResponse({"apiVersion": 1, "serverVersion": server_version(), "status": state["status"],
                             "metadata": metadata(), "sampleRate": RATE, "channels": 1,
                             "encoding": "pcm_s16le_wav", "maxSeconds": 24, "maxBytes": MAX_BYTES,
                             "preprocessing": preprocessing, "vocabulary": vocabulary_size(),
                             "precision": precision(), "speakerLabels": labeler.status if labeler else "off",
                             "vocabularyUpload": True},
                            status_code=200 if ready() else 503,
                            headers={"Cache-Control": "no-store"})

    def run_inference(chunk, pcm):
        """Runs on the single inference thread: preprocess, ASR, optional speakers."""
        started = time.monotonic()
        preprocess_ms, asr_ms, speaker_ms = 0.0, 0.0, 0.0
        audio = None
        model_pcm = pcm
        if preprocessing or labeler:
            audio = pcm_to_float(pcm)
        if preprocessing:
            try:
                preprocess_started = time.monotonic()
                audio = preprocess(audio)
                model_pcm = float_to_pcm(audio)
                preprocess_ms = (time.monotonic() - preprocess_started) * 1_000
            except Exception as error:  # cleanup is an enhancement, never a reason to drop speech
                if not state["preprocess_warned"]:
                    state["preprocess_warned"] = True
                    log.warning("Förbehandling misslyckades (%s); originalljudet används.", type(error).__name__)
        asr_started = time.monotonic()
        words = validate_backend_words(backend.transcribe(model_pcm), len(pcm) // 2)
        asr_ms = (time.monotonic() - asr_started) * 1_000
        if labeler:
            speaker_started = time.monotonic()
            words = labeler.label(chunk, audio, words)
            speaker_ms = (time.monotonic() - speaker_started) * 1_000
        log.debug("perf request_ms=%.1f preprocess_ms=%.1f asr_ms=%.1f speaker_ms=%.1f samples=%d",
                  (time.monotonic() - started) * 1_000, preprocess_ms, asr_ms, speaker_ms, len(pcm) // 2)
        return words

    def run_reload(reload):
        """A word added from the phone takes effect here, on the inference thread (so it never
        races a transcription) and without a restart. Own words are an enhancement: a failing
        reload never stops the transcription, and the journal line has the type name only."""
        try:
            reload(timeout=reload_timeout)
        except Exception as error:
            log.warning("Egna ord kunde inte laddas om (%s); ordlistan är som förut.", type(error).__name__)

    def hold_until_reloaded(loop, pending):
        """A reload past its own limit: the chunk is answered 503 so the phone sends it again,
        and the service stays busy until the inference thread is free. Only a thread still
        blocked after `reload_limit` (as long as model loading may take) restarts the service,
        and then no transcription is running."""
        log.warning("Egna ord laddades inte om i tid (TimeoutError); delen skickas om efteråt.")

        def stuck():
            state["status"] = "failed"
            log.warning("Omladdningen av egna ord hänger (TimeoutError); tjänsten startas om.")
            fatal_exit(1)

        watchdog = loop.call_later(reload_limit, stuck)

        def reloaded(_):
            watchdog.cancel()
            state["busy"] = False

        pending.add_done_callback(reloaded)

    async def infer(key, fingerprint, chunk, pcm):
        release_busy = True
        try:
            loop = asyncio.get_running_loop()
            # The reload runs as its own job before the transcription, with its own shorter
            # limit, so it never counts against the inference limit below: a slow reload must
            # never be what restarts the service in the middle of a transcription.
            reload = getattr(backend, "reload_vocabulary_if_requested", None)
            if reload:
                pending = loop.run_in_executor(executor, run_reload, reload)
                done, _ = await asyncio.wait({pending}, timeout=reload_timeout)
                if not done:
                    release_busy = False
                    hold_until_reloaded(loop, pending)
                    raise RequestError(503, "vocabulary_reloading")
            words = await asyncio.wait_for(loop.run_in_executor(
                executor, run_inference, chunk, pcm), inference_timeout)
            result = {"apiVersion": 1, "sessionID": chunk.session_id, "chunkID": chunk.chunk_id,
                      "sequence": chunk.sequence, "startSample": chunk.start_sample,
                      "words": words, "metadata": metadata()}
            body = JSONResponse(result).body
            if len(body) > MAX_RESPONSE_BYTES and labeler:
                # Speaker labels are optional; text within the cap must still arrive.
                result["words"] = strip_speakers(words)
                body = JSONResponse(result).body
            if len(body) > MAX_RESPONSE_BYTES:
                raise RequestError(502, "model_result_too_large")
            cache[key] = (time.monotonic(), fingerprint, body)
            while len(cache) > 8:
                cache.popitem(last=False)
            return body
        except asyncio.TimeoutError:
            state["status"] = "failed"
            fatal_exit(1)
            raise RequestError(503, "inference_timeout") from None
        except RequestError:
            raise
        except Exception:
            state["status"] = "failed"
            fatal_exit(1)
            raise RequestError(503, "model_failed") from None
        finally:
            if release_busy:
                state["busy"] = False

    async def read_audio(request):
        data = bytearray()
        async for part in request.stream():
            if len(data) + len(part) > MAX_BYTES:
                raise RequestError(413, "audio_too_large")
            data.extend(part)
        return bytes(data)

    @app.post("/v1/transcribe")
    async def transcribe(request: Request):
        authenticate(request)
        if request.headers.get("content-type", "").split(";")[0] != "audio/wav" or request.headers.get("content-encoding"):
            raise RequestError(415, "wav_required")
        if not ready():
            raise RequestError(503, "model_not_ready")
        # Admission before body allocation: slow clients cannot build an unbounded queue.
        if state["busy"]:
            raise RequestError(429, "busy")
        state["busy"] = True
        handed_off = False
        try:
            chunk = Chunk.from_headers(request.headers)
            try:
                body = await asyncio.wait_for(read_audio(request), 10)
            except asyncio.TimeoutError:
                raise RequestError(408, "body_timeout") from None
            pcm = decode_wave(body, chunk)
            key = (chunk.session_id, chunk.chunk_id)
            fingerprint = chunk.fingerprint(body)
            prune_cache(time.monotonic())
            if key in cache:
                _, previous, result = cache[key]
                if previous != fingerprint:
                    raise RequestError(409, "chunk_conflict")
                return json_response(result)
            job = asyncio.create_task(infer(key, fingerprint, chunk, pcm))
            jobs.add(job)
            def finished(task):
                jobs.discard(task)
                if not task.cancelled():
                    task.exception()  # consume a failure even if the client disconnected
            job.add_done_callback(finished)
            handed_off = True
            result = await asyncio.shield(job)
            return json_response(result)
        finally:
            if not handed_off:
                state["busy"] = False

    async def read_small_body(request, limit):
        declared = request.headers.get("content-length", "")
        if declared.isdigit() and int(declared) > limit:
            raise RequestError(413, "body_too_large")
        data = bytearray()
        async for part in request.stream():
            if len(data) + len(part) > limit:
                raise RequestError(413, "body_too_large")
            data.extend(part)
        return bytes(data)

    @app.post("/v1/vocabulary")
    async def add_vocabulary(request: Request):
        """One own word she said Yes to on the phone. The word is never logged or passed on."""
        authenticate(request)
        if request.headers.get("content-type", "").split(";")[0].strip().lower() != "application/json" \
                or request.headers.get("content-encoding"):
            raise RequestError(415, "json_required")
        try:
            body = await asyncio.wait_for(read_small_body(request, MAX_VOCABULARY_BODY), 10)
        except asyncio.TimeoutError:
            raise RequestError(408, "body_timeout") from None
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise RequestError(400, "invalid_phrase") from None
        if not isinstance(payload, dict) or set(payload) != {"phrase"}:
            raise RequestError(400, "invalid_phrase")
        phrase = normalize_phrase(payload["phrase"])
        if phrase is None:
            raise RequestError(400, "invalid_phrase")
        try:
            added = vocabulary.add(phrase)
        except VocabularyFull:
            raise RequestError(409, "vocabulary_full") from None
        except OSError as error:
            # The list stays as it was; transcription is unaffected. Type name only, never the word.
            log.warning("Ett eget ord kunde inte sparas (%s); ordlistan är som förut.", type(error).__name__)
            raise RequestError(507, "vocabulary_storage_failed") from None
        if added:
            request_reload = getattr(backend, "request_vocabulary_reload", None)
            if request_reload:
                request_reload()
        return JSONResponse({"added": added, "vocabulary": vocabulary_size()}, headers={"Cache-Control": "no-store"})

    @app.delete("/v1/sessions/{session_id}")
    async def end_session(session_id: str, request: Request):
        """Optional: ends a session's speaker state and its cached text answers now."""
        authenticate(request)
        try:
            session_id = str(UUID(session_id))
        except ValueError:
            raise RequestError(400, "invalid_session") from None
        if labeler:
            labeler.sessions.end(session_id)
        for key in [key for key in cache if key[0] == session_id]:
            del cache[key]
        return Response(status_code=204, headers={"Cache-Control": "no-store"})

    return app
