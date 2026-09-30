import asyncio
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
import hmac
import os
import re
import time

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from .core import Chunk, MAX_BYTES, RATE, RequestError, decode_wave, normalize_words


def create_app(backend=None, token=None, inference_timeout=45, fatal_exit=os._exit, cache_ttl=90):
    token = token if token is not None else os.environ.get("MIO_TRANSCRIPTION_TOKEN", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        raise ValueError("Set a 32-256 character MIO_TRANSCRIPTION_TOKEN")
    if backend is None:
        from .backend import Pianissimo
        backend = Pianissimo()
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="inference")
    state = {"status": "loading", "busy": False}
    cache = OrderedDict()
    jobs = set()

    async def load():
        try:
            await asyncio.wait_for(asyncio.get_running_loop().run_in_executor(executor, backend.load), 300)
            state["status"] = "ready"
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

    @asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(load())
        cleanup = asyncio.create_task(expire_cache())
        yield
        task.cancel()
        cleanup.cancel()
        cache.clear()
        for job in jobs:
            job.cancel()
        executor.shutdown(wait=False, cancel_futures=True)

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
        return {"model": backend.model_id, "revision": backend.revision, "backend": "nemo-pytorch-cuda"}

    @app.get("/health")
    async def health(request: Request):
        authenticate(request)
        return JSONResponse({"apiVersion": 1, "serverVersion": "1.0.0", "status": state["status"],
                             "metadata": metadata(), "sampleRate": RATE, "channels": 1,
                             "encoding": "pcm_s16le_wav", "maxSeconds": 24, "maxBytes": MAX_BYTES},
                            status_code=200 if state["status"] == "ready" else 503,
                            headers={"Cache-Control": "no-store"})

    async def infer(key, fingerprint, chunk, pcm):
        try:
            words = await asyncio.wait_for(asyncio.get_running_loop().run_in_executor(
                executor, backend.transcribe, pcm), inference_timeout)
            words = normalize_words(words, len(pcm) // 2)
            result = {"apiVersion": 1, "sessionID": chunk.session_id, "chunkID": chunk.chunk_id,
                      "sequence": chunk.sequence, "startSample": chunk.start_sample,
                      "words": words, "metadata": metadata()}
            cache[key] = (time.monotonic(), fingerprint, result)
            while len(cache) > 8:
                cache.popitem(last=False)
            return result
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
        if state["status"] != "ready":
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
                return JSONResponse(result, headers={"Cache-Control": "no-store"})
            job = asyncio.create_task(infer(key, fingerprint, chunk, pcm))
            jobs.add(job)
            def finished(task):
                jobs.discard(task)
                if not task.cancelled():
                    task.exception()  # consume a failure even if the client disconnected
            job.add_done_callback(finished)
            handed_off = True
            result = await asyncio.shield(job)
            return JSONResponse(result, headers={"Cache-Control": "no-store"})
        finally:
            if not handed_off:
                state["busy"] = False

    return app
