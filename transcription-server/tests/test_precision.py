import contextlib
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

from mio_transcription.backend import Pianissimo, parse_precision


class FakeTorch:
    """Records the autocast settings that Pianissimo.transcribe asks for; no GPU needed."""
    float16 = "float16"

    def __init__(self):
        self.autocasts = []

    def inference_mode(self):
        return contextlib.nullcontext()

    def autocast(self, device_type, dtype=None, enabled=True):
        self.autocasts.append((device_type, dtype, enabled))
        return contextlib.nullcontext()


class Model:
    def transcribe(self, **kwargs):
        word = {"word": "hej", "start": 0.0, "end": 0.4}
        return [SimpleNamespace(text="hej", timestamp={"word": [word]})]


def service(monkeypatch, value=None):
    monkeypatch.setenv("MIO_MODEL_REVISION", "a" * 40)
    if value is None:
        monkeypatch.delenv("MIO_PRECISION", raising=False)
    else:
        monkeypatch.setenv("MIO_PRECISION", value)
    return Pianissimo()


def test_precision_defaults_to_fp32_and_only_accepts_known_values(monkeypatch):
    assert service(monkeypatch).precision == "fp32"
    assert service(monkeypatch, "  ").precision == "fp32"
    assert service(monkeypatch, "fp16").precision == "fp16"
    for value in ["FP16", "bf16", "half", "fp8", "16"]:
        with pytest.raises(ValueError):
            parse_precision(value)
        with pytest.raises(ValueError):
            service(monkeypatch, value)


@pytest.mark.parametrize("value,enabled", [("fp32", False), ("fp16", True)])
def test_fp16_runs_the_model_under_cuda_autocast_and_fp32_does_not(monkeypatch, value, enabled):
    torch = FakeTorch()
    monkeypatch.setitem(sys.modules, "torch", torch)
    backend = service(monkeypatch, value)
    backend.model = Model()
    words = backend.transcribe(bytes(16_000 * 2))
    assert torch.autocasts == [("cuda", "float16", enabled)]
    assert words == [{"text": "hej", "start": 0.0, "end": 0.4}], "word timings are unchanged by precision"
    assert set(backend.metadata()) == {"model", "revision", "backend"}, "the API metadata contract is unchanged"


def load_script():
    path = Path(__file__).resolve().parents[1] / "scripts/measure_wer.py"
    spec = importlib.util.spec_from_file_location("measure_wer_precision", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Backend:
    """Fake backend: answers with a fixed word and records the precision of each call."""
    def __init__(self):
        self.precision = "fp32"
        self.calls = []

    def transcribe(self, pcm):
        self.calls.append((self.precision, len(pcm)))
        return [{"text": "hej", "start": 0.0, "end": 0.1}]


def test_script_measures_each_precision_on_the_same_model_after_a_warm_up():
    import numpy as np
    script = load_script()
    items = [("a", np.zeros(16_000, dtype=np.float32), "hej")]
    backend = Backend()
    runs = [script.measure(backend, precision, ["ren"], items, seed=1) for precision in ("fp32", "fp16")]
    assert [run["precision"] for run in runs] == ["fp32", "fp16"]
    assert all(run["villkor"]["ren"] == {"yttranden": 1, "utan": 0.0, "med": 0.0} for run in runs)
    assert all(run["rtfx"] is None or run["rtfx"] > 0 for run in runs)
    # Per precision: one untimed warm-up of digital silence, then plain and preprocessed audio.
    assert [precision for precision, _ in backend.calls] == ["fp32"] * 3 + ["fp16"] * 3
    assert backend.calls[0][1] == 16_000 * 2 and backend.calls[3][1] == 16_000 * 2
