import logging
import os
import re
from typing import Protocol

from .core import normalize_words


class TranscriptionBackend(Protocol):
    """RAM PCM16/16 kHz in; normalized seconds and safe model provenance out."""
    def load(self) -> None: ...
    def is_ready(self) -> bool: ...
    def transcribe(self, pcm: bytes) -> list[dict]: ...
    def metadata(self) -> dict[str, str]: ...


class Pianissimo:
    def __init__(self):
        self.model_id = os.getenv("MIO_MODEL_ID", "KlangAI/pianissimo-sv")
        self.revision = os.environ["MIO_MODEL_REVISION"]
        if not re.fullmatch(r"[a-f0-9]{40}", self.revision):
            raise ValueError("MIO_MODEL_REVISION must be a commit SHA")
        self.model = None
        self.ready = False

    def load(self):
        # Import lazily so /health remains responsive while the GPU model loads.
        import torch
        from huggingface_hub import snapshot_download
        from nemo.collections.asr.models import ASRModel
        from pathlib import Path
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA required")
        folder = Path(snapshot_download(repo_id=self.model_id, revision=self.revision,
                                        allow_patterns=["*.nemo"]))
        files = list(folder.glob("*.nemo"))
        if len(files) != 1:
            raise RuntimeError("Expected one original NeMo checkpoint")
        logging.getLogger("nemo_logger").setLevel(logging.ERROR)
        self.model = ASRModel.restore_from(str(files[0]), map_location="cuda").eval()
        self.model.freeze()
        # Warm-up is part of readiness. No real microphone material is used.
        self.transcribe(bytes(16_000 * 2))
        self.ready = True

    def is_ready(self):
        return self.ready and self.model is not None

    def metadata(self):
        return {"model": self.model_id, "revision": self.revision, "backend": "nemo-pytorch-cuda"}

    def transcribe(self, pcm):
        import numpy as np
        import torch
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        # NeMo's tensor loader pads sub-second audio symmetrically by default.
        # Right padding here preserves the API's original zero-time anchor.
        if len(audio) < 16_000:
            audio = np.pad(audio, (0, 16_000 - len(audio)))
        with torch.inference_mode():
            hypotheses = self.model.transcribe(audio=[audio], batch_size=1,
                                              return_hypotheses=True, timestamps=True,
                                              verbose=False, num_workers=0)
        hypothesis = hypotheses[0]
        words = hypothesis.timestamp.get("word", [])
        if hypothesis.text.strip() and not words:
            raise RuntimeError("Model returned text without word timestamps")
        return normalize_words(words, len(pcm) // 2)
