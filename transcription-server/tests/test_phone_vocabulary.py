"""POST /v1/vocabulary: own words from the phone, with a synthetic model only."""
import copy
import logging
import os
import stat
import threading
import time

from fastapi.testclient import TestClient
import pytest

from mio_transcription.app import create_app
from mio_transcription.backend import Pianissimo
from mio_transcription.core import MAX_VOCABULARY
from mio_transcription.vocabulary import PhoneVocabulary, normalize_phrase, read_merged

from test_api import TOKEN, Backend, audio, headers
from test_vocabulary import Model

WORD = "Åsa Lindqvist"


class ReloadingBackend(Backend):
    """Records when the app asks for a reload and when it happens relative to transcription."""
    def __init__(self, store, fail_reload=False, reload_seconds=0, gate=None):
        super().__init__()
        self.reload_seconds = reload_seconds
        self.gate = gate
        self.timeouts = []
        self.store = store
        self.requested = False
        self.events = []
        self.active = len(store.phrases())
        self.fail_reload = fail_reload
    def vocabulary_size(self):
        return self.active
    def request_vocabulary_reload(self):
        self.requested = True
    def reload_vocabulary_if_requested(self, timeout=None):
        if not self.requested:
            return
        self.requested = False
        self.timeouts.append(timeout)
        self.events.append("reload")
        time.sleep(self.reload_seconds)
        if self.gate:
            self.gate.wait(5)
        if self.fail_reload:
            raise RuntimeError("decoder failed")
        self.active = len(self.store.phrases())
    def transcribe(self, pcm):
        self.events.append("transcribe")
        return super().transcribe(pcm)


@pytest.fixture
def files(tmp_path):
    etc = tmp_path / "etc-vocabulary.txt"
    etc.write_text("# Namn\nKlang AI\n", encoding="utf-8")
    return PhoneVocabulary(str(etc), str(tmp_path / "state" / "vocabulary-phone.txt"))


@pytest.fixture
def phone(files, tmp_path):
    (tmp_path / "state").mkdir()
    return files


def client_for(backend, store, **options):
    options.setdefault("fatal_exit", lambda _: None)
    client = TestClient(create_app(backend, TOKEN, diarizer=None, preprocessing=False, vocabulary=store,
                                   **options))
    return client


def ready(client):
    for _ in range(200):
        if client.get("/health", headers=headers()).status_code == 200:
            return
        time.sleep(.005)


def post(client, body, token=TOKEN, content_type="application/json"):
    data = body if isinstance(body, bytes) else __import__("json").dumps(body).encode()
    return client.post("/v1/vocabulary", content=data,
                       headers={"Authorization": f"Bearer {token}", "Content-Type": content_type})


def test_a_word_is_appended_once_and_reloaded_before_the_next_transcription(phone, caplog):
    backend = ReloadingBackend(phone)
    with caplog.at_level(logging.DEBUG, logger="mio_transcription"), client_for(backend, phone) as client:
        ready(client)
        health = client.get("/health", headers=headers()).json()
        assert health["vocabularyUpload"] is True and health["vocabulary"] == 1
        response = post(client, {"phrase": f"  {WORD} "})
        assert response.status_code == 200 and response.json() == {"added": True, "vocabulary": 1}
        assert response.headers["cache-control"] == "no-store"
        assert backend.requested and backend.events == []
        assert client.post("/v1/transcribe", content=audio(), headers=headers()).status_code == 200
        assert backend.events == ["reload", "transcribe"], "the list is read again before the transcription"
        assert client.get("/health", headers=headers()).json()["vocabulary"] == 2
        assert post(client, {"phrase": WORD}).json() == {"added": False, "vocabulary": 2}
        assert post(client, {"phrase": "Klang AI"}).json()["added"] is False, "the /etc list counts too"
        assert not backend.requested, "a word that already exists does not reload the decoder"
    text = open(phone.phone_path, encoding="utf-8").read()
    assert text == f"{WORD}\n"
    assert stat.S_IMODE(os.stat(phone.phone_path).st_mode) == 0o600
    assert "Åsa" not in caplog.text and "Lindqvist" not in caplog.text
    assert read_merged(phone.path, phone.phone_path) == ["Klang AI", WORD]


@pytest.mark.parametrize("body", [
    {"phrase": ""}, {"phrase": "   "}, {"phrase": "rad\nbrytning"}, {"phrase": "tab\tbort"},
    {"phrase": "nul\x00"}, {"phrase": "c1\x85x"}, {"phrase": "rad sep"}, {"phrase": "# kommentar"},
    {"phrase": "å" * 51}, {"phrase": "ab\ud800cd"}, {"phrase": "\udfff"}, {"phrase": 12}, {"phrase": None}, {"phrase": WORD, "extra": 1}, {}, [WORD], WORD,
    b"{not json", b"\xff\xfe",
])
def test_invalid_phrases_are_refused_and_the_list_is_unchanged(phone, body):
    backend = ReloadingBackend(phone)
    with client_for(backend, phone) as client:
        response = post(client, body)
        assert response.status_code == 400 and response.json() == {"error": "invalid_phrase"}
    assert not os.path.exists(phone.phone_path) and not backend.requested


def test_limits_auth_and_content_type(phone):
    backend = ReloadingBackend(phone)
    with client_for(backend, phone) as client:
        assert post(client, {"phrase": WORD}, token="x" * 40).status_code == 401
        assert post(client, {"phrase": WORD}, content_type="text/plain").status_code == 415
        too_large = post(client, b'{"phrase":"' + b"a" * 1_100 + b'"}')
        assert too_large.status_code == 413
        assert post(client, {"phrase": "x" * 100}).status_code == 200, "100 bytes is allowed"
    assert open(phone.phone_path, encoding="utf-8").read() == "x" * 100 + "\n"


def test_a_full_list_answers_409(phone):
    with open(phone.path, "w", encoding="utf-8") as file:
        file.write("\n".join(f"ord{index}" for index in range(MAX_VOCABULARY - 1)) + "\n")
    backend = ReloadingBackend(phone)
    with client_for(backend, phone) as client:
        assert post(client, {"phrase": "sista"}).json()["added"] is True
        response = post(client, {"phrase": "en till"})
        assert response.status_code == 409 and response.json() == {"error": "vocabulary_full"}
        assert post(client, {"phrase": "ord3"}).json()["added"] is False, "an existing word is still recognised"
    assert open(phone.phone_path, encoding="utf-8").read() == "sista\n"


def test_an_unwritable_state_directory_never_stops_transcription(files, caplog):
    # The state directory does not exist, so the write fails.
    backend = ReloadingBackend(files)
    with caplog.at_level(logging.WARNING, logger="mio_transcription"), client_for(backend, files) as client:
        ready(client)
        response = post(client, {"phrase": WORD})
        assert response.status_code == 507 and response.json() == {"error": "vocabulary_storage_failed"}
        assert client.post("/v1/transcribe", content=audio(), headers=headers()).status_code == 200
    assert "FileNotFoundError" in caplog.text and "Åsa" not in caplog.text


def test_a_failing_reload_never_stops_transcription(phone, caplog):
    backend = ReloadingBackend(phone, fail_reload=True)
    with caplog.at_level(logging.WARNING, logger="mio_transcription"), client_for(backend, phone) as client:
        ready(client)
        assert post(client, {"phrase": WORD}).status_code == 200
        response = client.post("/v1/transcribe", content=audio(), headers=headers())
        assert response.status_code == 200 and response.json()["words"][0]["text"] == "Hej"
    assert "RuntimeError" in caplog.text and "Åsa" not in caplog.text


def test_a_hand_edited_phone_file_without_final_newline_gets_a_new_line(phone):
    with open(phone.phone_path, "w", encoding="utf-8") as file:
        file.write("Rix Vox")
    assert phone.add("Pianissimo") is True
    assert open(phone.phone_path, encoding="utf-8").read() == "Rix Vox\nPianissimo\n"


def test_phrase_normalisation():
    assert normalize_phrase("  Åsa   Lindqvist ") == "Åsa Lindqvist"
    assert normalize_phrase("x" * 100) == "x" * 100 and normalize_phrase("x" * 101) is None
    assert normalize_phrase("ab\x7f") is None and normalize_phrase("#x") is None


def test_the_merged_list_puts_etc_first_and_keeps_at_most_500(tmp_path):
    etc, own = tmp_path / "etc.txt", tmp_path / "phone.txt"
    etc.write_text("\n".join(f"etc{index}" for index in range(400)), encoding="utf-8")
    own.write_text("etc1\n" + "\n".join(f"own{index}" for index in range(200)), encoding="utf-8")
    merged = read_merged(etc, own)
    assert len(merged) == MAX_VOCABULARY and merged[:2] == ["etc0", "etc1"] and merged[400] == "own0"


def pianissimo(monkeypatch, tmp_path, model):
    etc, own = tmp_path / "etc.txt", tmp_path / "phone.txt"
    etc.write_text("Klang AI\n", encoding="utf-8")
    monkeypatch.setenv("MIO_MODEL_REVISION", "a" * 40)
    monkeypatch.setenv("MIO_VOCABULARY_FILE", str(etc))
    monkeypatch.setenv("MIO_PHONE_VOCABULARY_FILE", str(own))
    service = Pianissimo()
    service.model = model
    service.failing = False
    def transcribe(pcm):
        if service.failing:
            raise RuntimeError("decoder failed")
        return []
    service.transcribe = transcribe
    service._load_vocabulary()
    return service, own


class Decoding(Model):
    """The synthetic model, with cfg.decoding following the applied strategy as NeMo's does."""
    def change_decoding_strategy(self, decoding):
        super().change_decoding_strategy(decoding)
        self.cfg.decoding = copy.deepcopy(decoding)


def test_pianissimo_reads_both_files_and_reloads_without_restart(monkeypatch, tmp_path):
    service, own = pianissimo(monkeypatch, tmp_path, Decoding())
    assert service.vocabulary_size() == 1
    service.reload_vocabulary_if_requested()
    assert len(service.model.applied) == 1, "nothing happens without a request"
    own.write_text(f"{WORD}\n", encoding="utf-8")
    service.request_vocabulary_reload()
    service.reload_vocabulary_if_requested()
    assert service.vocabulary_size() == 2
    assert service.model.cfg.decoding.greedy.boosting_tree["key_phrases_list"] == ["Klang AI", WORD]


def test_a_failing_reload_keeps_the_previous_decoder(monkeypatch, tmp_path, caplog):
    service, own = pianissimo(monkeypatch, tmp_path, Decoding())
    own.write_text(f"{WORD}\n", encoding="utf-8")
    service.failing = True
    service.request_vocabulary_reload()
    with caplog.at_level(logging.WARNING, logger="mio_transcription"):
        service.reload_vocabulary_if_requested()
    assert service.vocabulary_size() == 1
    assert service.model.cfg.decoding.greedy.boosting_tree["key_phrases_list"] == ["Klang AI"]
    assert "RuntimeError" in caplog.text and "Åsa" not in caplog.text


def test_a_lone_surrogate_is_refused_and_never_logged(phone, caplog):
    backend = ReloadingBackend(phone)
    body = b'{"phrase":"Hemligt\\ud800ord"}'
    with caplog.at_level(logging.DEBUG), client_for(backend, phone) as client:
        response = post(client, body)
    assert response.status_code == 400 and response.json() == {"error": "invalid_phrase"}
    assert "Hemligt" not in caplog.text and not [record for record in caplog.records if record.levelno >= logging.ERROR]
    assert not os.path.exists(phone.phone_path) and not backend.requested
    assert normalize_phrase("ab\ud800cd") is None


def test_a_slow_reload_does_not_count_against_the_inference_limit(phone):
    exits = []
    backend = ReloadingBackend(phone, reload_seconds=.3)
    with client_for(backend, phone, inference_timeout=.2, reload_timeout=2, fatal_exit=exits.append) as client:
        ready(client)
        assert post(client, {"phrase": WORD}).status_code == 200
        response = client.post("/v1/transcribe", content=audio(), headers=headers())
        assert response.status_code == 200 and response.json()["words"][0]["text"] == "Hej"
    assert exits == [], "a reload longer than the inference limit never restarts the service"
    assert backend.events == ["reload", "transcribe"] and backend.timeouts == [2]


def test_a_reload_past_its_own_limit_defers_the_chunk_without_a_restart(phone, caplog):
    exits = []
    backend = ReloadingBackend(phone, reload_seconds=.4)
    with caplog.at_level(logging.WARNING, logger="mio_transcription"), \
            client_for(backend, phone, reload_timeout=.05, fatal_exit=exits.append) as client:
        ready(client)
        assert post(client, {"phrase": WORD}).status_code == 200
        deferred = client.post("/v1/transcribe", content=audio(), headers=headers())
        assert deferred.status_code == 503 and deferred.json() == {"error": "vocabulary_reloading"}
        assert deferred.headers["retry-after"] == "5"
        # The inference thread is still busy with the reload: no second job is queued behind it.
        assert client.post("/v1/transcribe", content=audio(), headers=headers()).status_code == 429
        time.sleep(.6)
        again = client.post("/v1/transcribe", content=audio(), headers=headers())
        assert again.status_code == 200 and again.json()["words"][0]["text"] == "Hej"
        assert client.get("/health", headers=headers()).status_code == 200
    assert exits == [] and backend.events == ["reload", "transcribe"]
    assert "TimeoutError" in caplog.text and "Åsa" not in caplog.text


def test_only_an_inference_thread_stuck_past_the_reload_limit_restarts_the_service(phone, caplog):
    exits = []
    gate = threading.Event()
    backend = ReloadingBackend(phone, gate=gate)
    try:
        with caplog.at_level(logging.WARNING, logger="mio_transcription"), \
                client_for(backend, phone, reload_timeout=.05, reload_limit=.3, fatal_exit=exits.append) as client:
            ready(client)
            assert post(client, {"phrase": WORD}).status_code == 200
            assert client.post("/v1/transcribe", content=audio(), headers=headers()).status_code == 503
            assert exits == [], "a reload past its own limit alone never restarts the service"
            time.sleep(.5)
            assert exits == [1]
            gate.set()
    finally:
        gate.set()
    assert "Åsa" not in caplog.text


def test_a_reload_that_ends_after_its_limit_keeps_the_previous_decoder(monkeypatch, tmp_path, caplog):
    service, own = pianissimo(monkeypatch, tmp_path, Decoding())
    own.write_text(f"{WORD}\n", encoding="utf-8")
    plain = service.transcribe
    service.transcribe = lambda pcm: (time.sleep(.1), plain(pcm))[1]
    service.request_vocabulary_reload()
    with caplog.at_level(logging.WARNING, logger="mio_transcription"):
        service.reload_vocabulary_if_requested(timeout=.05)
    assert service.vocabulary_size() == 1
    assert service.model.cfg.decoding.greedy.boosting_tree["key_phrases_list"] == ["Klang AI"]
    assert "TimeoutError" in caplog.text and "Åsa" not in caplog.text
    assert not service.reload_requested, "a late reload is not repeated before every chunk"
