import copy
import logging
from types import SimpleNamespace

import pytest

from mio_transcription import backend as backend_module
from mio_transcription.backend import Pianissimo, apply_vocabulary, read_vocabulary
from mio_transcription.core import MAX_VOCABULARY, parse_vocabulary


def test_vocabulary_file_is_one_case_sensitive_phrase_per_line():
    text = "# Namn\n\nKlang AI\n  Pianissimo  \nklang ai\nKlang AI\nRix   Vox\n\tÅsa-Märta Öberg\n"
    assert parse_vocabulary(text) == ["Klang AI", "Pianissimo", "klang ai", "Rix Vox", "Åsa-Märta Öberg"]
    assert parse_vocabulary("") == [] and parse_vocabulary("# bara kommentar\n\n") == []
    assert parse_vocabulary("ok\n" + "å" * 51 + "\nbad\x07word\n" + "x" * 100) == ["ok", "x" * 100]
    assert len(parse_vocabulary("\n".join(f"ord{index}" for index in range(MAX_VOCABULARY + 50)))) == MAX_VOCABULARY


def test_missing_or_unreadable_vocabulary_file_means_no_own_words(tmp_path, caplog):
    assert read_vocabulary(tmp_path / "missing.txt") == []
    path = tmp_path / "ordlista.txt"
    path.write_bytes(b"\xff\xfe not utf-8")
    with caplog.at_level(logging.WARNING, logger="mio_transcription"):
        assert read_vocabulary(path) == []
    assert "UnicodeDecodeError" in caplog.text
    path.write_text("Pianissimo\n", encoding="utf-8")
    assert read_vocabulary(path) == ["Pianissimo"]


class Model:
    """Stands in for the NeMo model: a decoding config and the method that applies one."""
    def __init__(self, fail_on_boost=False):
        self.cfg = SimpleNamespace(decoding=SimpleNamespace(strategy="greedy", greedy=SimpleNamespace(max_symbols=10)))
        self.applied = []
        self.fail_on_boost = fail_on_boost
    def change_decoding_strategy(self, decoding):
        if self.fail_on_boost and hasattr(decoding.greedy, "boosting_tree"):
            raise RuntimeError("boosting is not supported by this build")
        self.applied.append(copy.deepcopy(decoding))


def test_phrase_boosting_follows_the_model_card_and_keeps_other_decoding_settings():
    model = Model()
    assert apply_vocabulary(model, ["Klang AI", "Pianissimo"], 1.0) is True
    decoding = model.applied[-1]
    assert decoding.strategy == "greedy_batch" and decoding.greedy.max_symbols == 10
    assert decoding.greedy.boosting_tree == {"key_phrases_list": ["Klang AI", "Pianissimo"], "context_score": 1.0,
                                             "depth_scaling": 2.0, "use_triton": False}
    assert decoding.greedy.boosting_tree_alpha == 1.0
    assert model.cfg.decoding.strategy == "greedy", "the model's own configuration object is not edited in place"
    for phrases, alpha in [([], 1.0), (["Klang AI"], 0)]:
        untouched = Model()
        assert apply_vocabulary(untouched, phrases, alpha) is False and untouched.applied == []


def loaded(monkeypatch, tmp_path, model, text="Klang AI\nPianissimo\n", fail_transcribe_when_boosted=False):
    path = tmp_path / "ordlista.txt"
    path.unlink(missing_ok=True)
    if text is not None:
        path.write_text(text, encoding="utf-8")
    monkeypatch.setenv("MIO_MODEL_REVISION", "a" * 40)
    monkeypatch.setenv("MIO_VOCABULARY_FILE", str(path))
    service = Pianissimo()
    service.model = model
    warmups = []
    def transcribe(pcm):
        boosted = bool(model.applied) and hasattr(model.applied[-1].greedy, "boosting_tree")
        warmups.append(boosted)
        if boosted and fail_transcribe_when_boosted:
            raise RuntimeError("decoder failed")
        return []
    service.transcribe = transcribe
    service._load_vocabulary()
    return service, warmups


def test_backend_reports_the_number_of_own_words_only_when_boosting_is_active(monkeypatch, tmp_path):
    service, warmups = loaded(monkeypatch, tmp_path, Model())
    assert service.vocabulary_size() == 2 and warmups == [True]
    service, warmups = loaded(monkeypatch, tmp_path, Model(), text=None)
    assert service.vocabulary_size() == 0 and warmups == [False] and service.model.applied == []
    monkeypatch.setenv("MIO_VOCABULARY_BOOST", "0")
    service, _ = loaded(monkeypatch, tmp_path, Model())
    assert service.vocabulary_size() == 0 and service.model.applied == []


@pytest.mark.parametrize("fail_on_boost,fail_transcribe", [(True, False), (False, True)])
def test_a_failing_vocabulary_never_blocks_transcription_or_logs_the_words(monkeypatch, tmp_path, caplog,
                                                                         fail_on_boost, fail_transcribe):
    model = Model(fail_on_boost=fail_on_boost)
    with caplog.at_level(logging.WARNING, logger="mio_transcription"):
        service, warmups = loaded(monkeypatch, tmp_path, model, fail_transcribe_when_boosted=fail_transcribe)
    assert service.vocabulary_size() == 0
    assert warmups[-1] is False, "the final warm-up runs on the model's plain decoder"
    assert not hasattr(model.applied[-1].greedy, "boosting_tree") and model.applied[-1].strategy == "greedy"
    assert "RuntimeError" in caplog.text and "Klang" not in caplog.text and "Pianissimo" not in caplog.text


def test_a_failing_plain_warm_up_still_fails_the_load(monkeypatch, tmp_path):
    monkeypatch.setenv("MIO_MODEL_REVISION", "a" * 40)
    monkeypatch.setenv("MIO_VOCABULARY_FILE", str(tmp_path / "missing.txt"))
    service = Pianissimo()
    service.model = Model()
    def transcribe(pcm):
        raise RuntimeError("CUDA failed")
    service.transcribe = transcribe
    with pytest.raises(RuntimeError):
        service._load_vocabulary()


@pytest.mark.parametrize("value", ["3", "-1", "abc", "1.234", "2.5"])
def test_boost_strength_is_bounded(monkeypatch, value):
    monkeypatch.setenv("MIO_MODEL_REVISION", "a" * 40)
    monkeypatch.setenv("MIO_VOCABULARY_BOOST", value)
    with pytest.raises(ValueError):
        Pianissimo()
    assert backend_module.parse_vocabulary is parse_vocabulary
