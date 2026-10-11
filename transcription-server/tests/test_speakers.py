from types import SimpleNamespace

import numpy as np
import pytest

from mio_transcription.speakers import (SpeakerLabeler, SpeakerSessions, assign_speakers,
                                        segments_from_probabilities, strip_speakers, valid_segments)


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def chunk(session="s", core_start=16_000, core_end=48_000):
    return SimpleNamespace(session_id=session, core_start=core_start, core_end=core_end)


WORDS = [{"text": "före", "start": 0.2, "end": 0.6},     # left context
         {"text": "hej", "start": 1.1, "end": 1.5},
         {"text": "hallå", "start": 2.0, "end": 2.6},
         {"text": "tyst", "start": 2.8, "end": 2.9},
         {"text": "efter", "start": 3.2, "end": 3.6}]   # right context


def test_words_get_the_speaker_with_most_overlap_inside_owned_region():
    segments = [(0.0, 0.8, 0), (0.7, 1.3, 1), (0.9, 1.2, 0)]  # relative to core start (1.0 s)
    labeled = assign_speakers(WORDS, segments, 1.0, 1.0, 3.0)
    assert [word["speaker"] for word in labeled] == [None, 1, 2, None, None]
    assert labeled[1]["text"] == "hej" and "speaker" not in WORDS[1]
    assert strip_speakers(labeled) == WORDS


def test_zero_length_word_uses_its_point():
    word = [{"text": "å", "start": 1.5, "end": 1.5}]
    assert assign_speakers(word, [(0.4, 0.6, 3)], 1.0, 1.0, 3.0)[0]["speaker"] == 4


def test_probability_runs_become_segments():
    probabilities = np.array([[.9, .1], [.8, .7], [.1, .9], [.1, .1], [.9, .1]])
    assert segments_from_probabilities(probabilities, 0.08) == pytest.approx(
        [(0.0, 0.16, 0), (0.08, 0.24, 1), (0.32, 0.4, 0)])
    assert segments_from_probabilities(np.zeros((0, 4)), 0.08) == []


@pytest.mark.parametrize("segments", [[(0, 1, 4)], [(0, 1, -1)], [(1, 0.5, 0)], [(0, float("nan"), 0)],
                                      [(0, 99, 0)], [(0, 1, True)], [(0, 1, 1.5)], "not a list"])
def test_invalid_segments_are_rejected(segments):
    with pytest.raises((ValueError, TypeError)):
        valid_segments(segments, 2.0)


def test_sessions_expire_after_idle_ttl_and_are_bounded():
    clock = Clock()
    sessions = SpeakerSessions(ttl=600, max_sessions=2, clock=clock)
    for name in ("a", "b", "c"):
        sessions.checkin(name, sessions.checkout(name, lambda: name.upper()))
    assert len(sessions) == 2                                    # oldest ("a") evicted
    assert sessions.checkout("a", lambda: "new") == "new"
    sessions.checkin("b", sessions.checkout("b", lambda: "unused"))
    clock.now = 599
    assert sessions.checkout("b", lambda: "new") == "B"          # still alive, refreshed below
    sessions.checkin("b", "B")
    clock.now = 1200
    sessions.expire()
    assert len(sessions) == 0


def test_ended_session_is_not_resurrected_by_an_inflight_job():
    clock = Clock()
    sessions = SpeakerSessions(ttl=600, clock=clock)
    state = sessions.checkout("a", lambda: "state")
    sessions.end("a")
    sessions.checkin("a", state)
    assert len(sessions) == 0
    assert sessions.checkout("a", lambda: "new") is None
    clock.now = 600
    assert sessions.checkout("a", lambda: "new") == "new"        # tombstone is ID-only and expires too
    sessions.clear()
    assert len(sessions) == 0


class CountingDiarizer:
    """Fake: speaker index = how many chunks this session's state has seen, mod 4."""
    def __init__(self):
        self.lengths = []
        self.fail = False

    def load(self):
        pass

    def new_state(self):
        return {"chunks": 0}

    def diarize(self, audio, state):
        if self.fail:
            raise RuntimeError("synthetic failure with private detail")
        self.lengths.append(len(audio))
        speaker = state["chunks"] % 4
        return [(0.0, len(audio) / 16_000, speaker)], {"chunks": state["chunks"] + 1}


def test_labeler_keeps_state_per_session_and_feeds_only_owned_audio():
    diarizer = CountingDiarizer()
    labeler = SpeakerLabeler(diarizer)
    labeler.load()
    audio = np.zeros(4 * 16_000, dtype=np.float32)
    first = labeler.label(chunk("a"), audio, WORDS)
    second = labeler.label(chunk("a"), audio, WORDS)
    other = labeler.label(chunk("b"), audio, WORDS)
    assert [w["speaker"] for w in first] == [None, 1, 1, 1, None]
    assert second[1]["speaker"] == 2 and other[1]["speaker"] == 1
    assert diarizer.lengths == [32_000] * 3


def test_labeler_failure_returns_words_without_speakers_and_logs_no_detail(caplog):
    diarizer = CountingDiarizer()
    labeler = SpeakerLabeler(diarizer)
    labeler.load()
    labeler.label(chunk("a"), np.zeros(64_000, dtype=np.float32), WORDS)
    diarizer.fail = True
    words = labeler.label(chunk("a"), np.zeros(64_000, dtype=np.float32), WORDS)
    assert [w["speaker"] for w in words] == [None] * 5
    assert [w["text"] for w in words] == [w["text"] for w in WORDS]
    assert len(labeler.sessions) == 0                       # possibly corrupt state is dropped
    assert "private detail" not in caplog.text and "RuntimeError" in caplog.text


def test_failed_load_turns_labels_off():
    diarizer = CountingDiarizer()
    diarizer.load = lambda: (_ for _ in ()).throw(OSError("no model"))
    labeler = SpeakerLabeler(diarizer)
    labeler.load()
    assert labeler.status == "off"
    assert labeler.label(chunk(), np.zeros(64_000, dtype=np.float32), WORDS) == WORDS
