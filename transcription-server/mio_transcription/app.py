import asyncio
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
import hmac
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

log = logging.getLogger("mio_transcription")


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
               diarizer=None, preprocessing=None, speaker_ttl=600, speaker_clock=time.monotonic):
    token = token if token is not None else os.environ.get("MIO_TRANSCRIPTION_TOKEN", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        raise ValueError("Set a 32-256 character MIO_TRANSCRIPTION_TOKEN")
    preprocessing = env_flag("MIO_PREPROCESS", True) if preprocessing is None else preprocessing
    if backend is None:
        from .backend import Pianissimo
        backend = Pianissimo()
        if diarizer is None:
            diarizer = default_diarizer()
    labeler = SpeakerLabeler(diarizer, ttl=speaker_ttl, clock=speaker_clock) if diarizer else None
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="inference")
    # Speaker model loading must never delay or block transcription readiness.
    side_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="speaker-load")
    state = {"status": "loading", "busy": False, "preprocess_warned": False}
    cache = OrderedDict()
    jobs = set()

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
            for key in list(cache):
                if time.monotonic() - cache[key][0] >= cache_ttl:
                    del cache[key]
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

    def json_response(body):
        return Response(body, media_type="application/json", headers={"Cache-Control": "no-store"})

    @app.get("/health")
    async def health(request: Request):
        authenticate(request)
        return JSONResponse({"apiVersion": 1, "serverVersion": "1.0.0", "status": state["status"],
                             "metadata": metadata(), "sampleRate": RATE, "channels": 1,
                             "encoding": "pcm_s16le_wav", "maxSeconds": 24, "maxBytes": MAX_BYTES,
                             "preprocessing": preprocessing,
                             "speakerLabels": labeler.status if labeler else "off"},
                            status_code=200 if ready() else 503,
                            headers={"Cache-Control": "no-store"})

    def run_inference(chunk, pcm):
        """Runs on the single inference thread: preprocess, ASR, optional speakers."""
        audio = pcm_to_float(pcm)
        model_pcm = pcm
        if preprocessing:
            try:
                audio = preprocess(audio)
                model_pcm = float_to_pcm(audio)
            except Exception as error:  # cleanup is an enhancement, never a reason to drop speech
                if not state["preprocess_warned"]:
                    state["preprocess_warned"] = True
                    log.warning("Förbehandling misslyckades (%s); originalljudet används.", type(error).__name__)
        words = validate_backend_words(backend.transcribe(model_pcm), len(pcm) // 2)
        return labeler.label(chunk, audio, words) if labeler else words

    async def infer(key, fingerprint, chunk, pcm):
        try:
            words = await asyncio.wait_for(asyncio.get_running_loop().run_in_executor(
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
            for old_key in list(cache):
                if time.monotonic() - cache[old_key][0] >= cache_ttl:
                    del cache[old_key]
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
