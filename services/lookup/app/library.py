"""Port to the shared word-clip library (FEAT-006).

The lookup service asks the library for the stored clip of a sense; a miss is
handed to the generation path. The shared library is a later component, so the
default port is an empty in-memory store and the service reports a miss.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal, Protocol

from .models import PartOfSpeech

LibraryKey = tuple[str, str, PartOfSpeech]


@dataclass(frozen=True)
class LibraryClip:
    """A stored clip served for a library entry."""

    url: str
    duration_seconds: float
    has_audio: bool
    resolution: Literal["360p"] = "360p"


@dataclass(frozen=True)
class LibraryEntry:
    """A shared library entry for one sense of a word."""

    id: str
    gloss_phrase: str
    # Whether the stored phrase is the fixed fallback template rather than a
    # generated phrase, so the served result can mark the meaning as a best
    # guess (schema "LibraryEntry", FEAT-004).
    gloss_phrase_is_fallback: bool
    clip: LibraryClip


class LibraryPort(Protocol):
    """Port for the shared word-clip library."""

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> LibraryEntry | None:
        """Return the entry for a sense, or None when the library has no hit."""
        ...


class InMemoryLibrary:
    """An in-memory library, keyed by lemma, sense label, and part of speech."""

    def __init__(self, entries: Mapping[LibraryKey, LibraryEntry] | None = None) -> None:
        self._entries: dict[LibraryKey, LibraryEntry] = dict(entries or {})

    async def find(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
    ) -> LibraryEntry | None:
        return self._entries.get((lemma.casefold(), sense_label, part_of_speech))

    def add(
        self,
        lemma: str,
        sense_label: str,
        part_of_speech: PartOfSpeech,
        entry: LibraryEntry,
    ) -> None:
        self._entries[(lemma.casefold(), sense_label, part_of_speech)] = entry
