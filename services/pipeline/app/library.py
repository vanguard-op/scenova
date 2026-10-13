"""Port to the shared word-clip library (FEAT-006).

A finished word clip is written here, keyed by lemma, sense, and part of speech,
so a later lookup serves it without generating again. Phrase clips are never
written here. The shared library is a later component, so the default port is an
in-memory store.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from .jobs import ClipAsset, LibraryEntry
from .models import PartOfSpeech

LibraryKey = tuple[str, str, PartOfSpeech]


@dataclass(frozen=True)
class StoredClip:
    """A library entry and the clip asset it references."""

    entry: LibraryEntry
    asset: ClipAsset


class LibraryWriter(Protocol):
    """Port for writing a word clip to the shared library."""

    async def store(self, entry: LibraryEntry, asset: ClipAsset) -> None: ...


class InMemoryLibraryWriter:
    """An in-memory library, keyed by lemma, sense label, and part of speech."""

    def __init__(self) -> None:
        self._clips: dict[LibraryKey, StoredClip] = {}

    async def store(self, entry: LibraryEntry, asset: ClipAsset) -> None:
        key: LibraryKey = (entry.lemma.casefold(), entry.sense_label, entry.part_of_speech)
        self._clips[key] = StoredClip(entry=entry, asset=asset)

    def find(self, lemma: str, sense_label: str, part_of_speech: PartOfSpeech) -> StoredClip | None:
        return self._clips.get((lemma.casefold(), sense_label, part_of_speech))

    def all(self) -> tuple[StoredClip, ...]:
        return tuple(self._clips.values())
