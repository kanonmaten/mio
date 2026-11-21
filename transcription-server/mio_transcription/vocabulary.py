"""The user's own words: the root-owned list in /etc and the list she adds from the phone.

The /etc file is edited by hand and the hardened service cannot write it, so words sent from
the phone go to a separate file in the service's own state directory. Both are read together,
the /etc file first, and at most MAX_VOCABULARY phrases are used. A phrase is never logged and
never leaves the PC.
"""

import logging
import os

from .core import MAX_VOCABULARY, parse_vocabulary

log = logging.getLogger("mio_transcription")

DEFAULT_FILE = "/etc/mio-transcription-vocabulary.txt"
DEFAULT_PHONE_FILE = "/var/lib/mio-transcription/vocabulary-phone.txt"
MAX_PHRASE_BYTES = 100


def _read(path):
    """Phrases from one file; a missing or unreadable file means none."""
    try:
        with open(path, encoding="utf-8") as file:
            return parse_vocabulary(file.read(1_000_000))
    except FileNotFoundError:
        return []
    except (OSError, UnicodeError) as error:
        log.warning("Ordlistan kunde inte läsas (%s); transkriptionen fortsätter utan egna ord.", type(error).__name__)
        return []


def read_merged(path, phone_path):
    """The /etc list first, then the phone's, without duplicates, at most MAX_VOCABULARY."""
    return parse_vocabulary("\n".join(_read(path) + _read(phone_path)))


def normalize_phrase(value):
    """The phrase as it will be stored, or None when it breaks the contract.

    Trimmed; 1-100 UTF-8 bytes; no line breaks or other control characters (C0, DEL, C1,
    U+2028/U+2029); not a comment. Inner runs of spaces are collapsed, as the list reader does.
    """
    if not isinstance(value, str):
        return None
    phrase = value.strip()
    if any(ord(character) < 32 or 127 <= ord(character) <= 159 or character in "  "
           for character in phrase):
        return None
    phrase = " ".join(phrase.split())
    if not phrase or phrase.startswith("#") or len(phrase.encode("utf-8")) > MAX_PHRASE_BYTES:
        return None
    return phrase


class VocabularyFull(Exception):
    pass


class PhoneVocabulary:
    def __init__(self, path=None, phone_path=None):
        self.path = path or os.environ.get("MIO_VOCABULARY_FILE", "").strip() or DEFAULT_FILE
        self.phone_path = phone_path or os.environ.get("MIO_PHONE_VOCABULARY_FILE", "").strip() or DEFAULT_PHONE_FILE

    def phrases(self):
        return read_merged(self.path, self.phone_path)

    def add(self, phrase):
        """Appends `phrase` (already normalized) unless either list has it. True when added.

        Raises VocabularyFull when MAX_VOCABULARY phrases are already in use, and OSError when
        the phone file cannot be written; the file is then as it was before the call.
        """
        if phrase in _read(self.path) or phrase in _read(self.phone_path):
            return False
        if len(self.phrases()) >= MAX_VOCABULARY:
            raise VocabularyFull()
        # The file is the service's own (state directory, 0600). One short write with O_APPEND,
        # starting on a new line if a hand edit left the last line open.
        descriptor = os.open(self.phone_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            ends_open = os.fstat(descriptor).st_size > 0 and not _ends_with_newline(self.phone_path)
            os.write(descriptor, (("\n" if ends_open else "") + phrase + "\n").encode("utf-8"))
        finally:
            os.close(descriptor)
        return True


def _ends_with_newline(path):
    with open(path, "rb") as file:
        file.seek(-1, os.SEEK_END)
        return file.read(1) == b"\n"
