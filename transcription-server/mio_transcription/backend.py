import logging
import os
import re
from typing import Protocol

from .core import normalize_words, parse_vocabulary

log = logging.getLogger("mio_transcription")

PRECISIONS = ("fp32", "fp16")


def parse_precision(value):
    """MIO_PRECISION: fp32 (default) or fp16. Anything else stops the service instead of guessing."""
    value = (value or "").strip() or "fp32"
    if value not in PRECISIONS:
        raise ValueError("MIO_PRECISION must be fp32 or fp16")
    return value


def read_vocabulary(path):
    """Phrases from the vocabulary file; a missing or unreadable file means none."""
    try:
        with open(path, encoding="utf-8") as file:
            return parse_vocabulary(file.read(1_000_000))
    except FileNotFoundError:
        return []
    except (OSError, UnicodeError) as error:
        log.warning("Ordlistan kunde inte läsas (%s); transkriptionen fortsätter utan egna ord.", type(error).__name__)
        return []


def apply_vocabulary(model, phrases, alpha):
    """Turns on NeMo phrase boosting as the Pianissimo model card describes it.

    Returns True when the decoder was changed. Phrases are never logged.
    """
    if not phrases or alpha <= 0:
        return False
    import contextlib
    import copy
    try:
        from omegaconf import open_dict
    except ImportError:  # only in tests with a synthetic model
        open_dict = contextlib.nullcontext
    decoding = copy.deepcopy(model.cfg.decoding)
    with open_dict(decoding):
        decoding.strategy = "greedy_batch"
        decoding.greedy.boosting_tree = {"key_phrases_list": list(phrases), "context_score": 1.0,
                                         "depth_scaling": 2.0, "use_triton": False}
        decoding.greedy.boosting_tree_alpha = alpha
    model.change_decoding_strategy(decoding)
    return True


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
        # The user's own names and terms (see README "Egna ord"). Strength 1.0 gave the best
        # trade-off in KlangAI's measurements: more names right, other text almost unchanged.
        self.vocabulary_path = os.getenv("MIO_VOCABULARY_FILE", "/etc/mio-transcription-vocabulary.txt")
        boost = os.getenv("MIO_VOCABULARY_BOOST", "").strip() or "1.0"
        if not re.fullmatch(r"[0-2](\.[0-9]{1,2})?", boost) or float(boost) > 2:
            raise ValueError("MIO_VOCABULARY_BOOST must be 0-2")
        self.vocabulary_boost = float(boost)
        self.vocabulary = 0
        self.precision = parse_precision(os.getenv("MIO_PRECISION"))

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
        # The warm-up below runs in the chosen precision, so readiness covers it.
        self._load_vocabulary()
        self.ready = True

    def _load_vocabulary(self):
        """Own words are an enhancement: any failure falls back to the model's plain decoder."""
        import copy
        phrases = read_vocabulary(self.vocabulary_path)
        original = copy.deepcopy(self.model.cfg.decoding) if phrases else None
        boosted = False
        try:
            boosted = apply_vocabulary(self.model, phrases, self.vocabulary_boost)
            # Warm-up is part of readiness. No real microphone material is used.
            self.transcribe(bytes(16_000 * 2))
        except Exception as error:
            if original is None:
                raise
            log.warning("Egna ord kunde inte aktiveras (%s); transkriptionen fortsätter utan dem.", type(error).__name__)
            boosted = False
            self.model.change_decoding_strategy(original)
            self.transcribe(bytes(16_000 * 2))
        self.vocabulary = len(phrases) if boosted else 0

    def vocabulary_size(self):
        return self.vocabulary

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
        # fp16 is NeMo's AMP inference path (transcribe_speech.py amp=True): weights stay fp32 and
        # matrix math runs in fp16 on the tensor cores. NeMo's mel preprocessor disables autocast
        # for its STFT and filterbank, so audio features stay fp32. Casting the whole model to
        # fp16 instead would also round the filterbank buffers.
        with torch.inference_mode(), torch.autocast("cuda", dtype=torch.float16,
                                                    enabled=self.precision == "fp16"):
            hypotheses = self.model.transcribe(audio=[audio], batch_size=1,
                                              return_hypotheses=True, timestamps=True,
                                              verbose=False, num_workers=0)
        hypothesis = hypotheses[0]
        words = hypothesis.timestamp.get("word", [])
        if hypothesis.text.strip() and not words:
            raise RuntimeError("Model returned text without word timestamps")
        return normalize_words(words, len(pcm) // 2)
