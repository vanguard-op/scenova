"""Lemma and sense inventory (FEAT-003, D-009).

The production source is a self-hosted, open-source lemmatiser over a
WordNet-style sense inventory; this module defines the port it plugs into plus a
seeded inventory that covers the behaviour the phase must show and keeps the
service self-contained. An inflected form resolves to its base form through the
seeded form index, and an unknown form falls back to rule-generated candidate
lemmas that only match a known entry, so a rule never invents a base form.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Protocol

from .models import PartOfSpeech


class InventoryUnavailableError(Exception):
    """Raised when the sense inventory cannot be reached."""


@dataclass(frozen=True)
class SenseRecord:
    """One sense of a word in the inventory."""

    part_of_speech: PartOfSpeech
    sense_label: str
    gloss_phrase: str
    rank: int
    common: bool = True


@dataclass(frozen=True)
class ResolvedWord:
    """The base form and common senses of a known word."""

    lemma: str
    senses: tuple[SenseRecord, ...]
    best_guess: bool


class SenseInventory(Protocol):
    """Port for the lemma and sense data source."""

    def resolve(self, token: str) -> ResolvedWord | None:
        """Resolve a token to its base form and senses, or None when unknown."""
        ...


class SeededSenseInventory:
    """An in-memory inventory built from seeded entries and inflected forms."""

    def __init__(
        self,
        entries: Mapping[str, tuple[SenseRecord, ...]],
        forms: Mapping[str, str],
    ) -> None:
        self._entries = {lemma.casefold(): senses for lemma, senses in entries.items()}
        self._forms = {form.casefold(): lemma.casefold() for form, lemma in forms.items()}

    def resolve(self, token: str) -> ResolvedWord | None:
        folded = token.casefold()
        lemma = self._forms.get(folded)
        if lemma is None:
            lemma = self._match_candidate(folded)
        if lemma is None or lemma not in self._entries:
            return None
        records = tuple(sorted(self._entries[lemma], key=lambda sense: sense.rank))
        common = tuple(record for record in records if record.common) or records[:1]
        return ResolvedWord(lemma=lemma, senses=common, best_guess=False)

    def _match_candidate(self, folded: str) -> str | None:
        for candidate in _lemma_candidates(folded):
            if candidate in self._entries:
                return candidate
        return None


def _lemma_candidates(word: str) -> list[str]:
    """Candidate base forms for an inflected word, from common English rules."""

    candidates: list[str] = []

    def add(candidate: str) -> None:
        if candidate and candidate not in candidates:
            candidates.append(candidate)

    if word.endswith("ies") and len(word) > 3:
        add(word[:-3] + "y")
    if word.endswith("es") and len(word) > 2:
        add(word[:-2])
        add(word[:-1])
    if word.endswith("s") and not word.endswith("ss") and len(word) > 1:
        add(word[:-1])
    if word.endswith("ing") and len(word) > 4:
        stem = word[:-3]
        add(stem)
        add(stem + "e")
        if len(stem) > 2 and stem[-1] == stem[-2]:
            add(stem[:-1])
    if word.endswith("ed") and len(word) > 3:
        stem = word[:-2]
        add(stem)
        add(stem + "e")
        if len(stem) > 2 and stem[-1] == stem[-2]:
            add(stem[:-1])
    if word.endswith("er") and len(word) > 3:
        add(word[:-2])
        add(word[:-1])
    if word.endswith("est") and len(word) > 4:
        add(word[:-3])
        add(word[:-2])
    return candidates


_SenseSpec = tuple[PartOfSpeech, str, str]
_WordSpec = tuple[str, tuple[str, ...], tuple[_SenseSpec, ...]]

_WORDS: tuple[_WordSpec, ...] = (
    (
        "come",
        ("come", "comes", "coming", "came"),
        ((PartOfSpeech.VERB, "arrive", "to move toward or reach a place"),),
    ),
    (
        "educate",
        ("educate", "educates", "educated", "educating", "education", "educational"),
        ((PartOfSpeech.VERB, "teach", "to teach or give knowledge to someone"),),
    ),
    (
        "bank",
        ("bank", "banks", "banked", "banking"),
        (
            (PartOfSpeech.NOUN, "financial_institution", "a business that keeps money for people"),
            (PartOfSpeech.NOUN, "river_edge", "the land along the side of a river"),
            (PartOfSpeech.VERB, "tilt", "to tilt an aircraft when turning"),
        ),
    ),
    (
        "light",
        ("light", "lights", "lighted", "lighting", "lighter", "lightest"),
        (
            (PartOfSpeech.NOUN, "illumination", "the brightness that lets you see things"),
            (PartOfSpeech.ADJECTIVE, "not_heavy", "weighing little and easy to lift"),
        ),
    ),
    (
        "run",
        ("run", "runs", "running", "ran"),
        (
            (PartOfSpeech.VERB, "move_fast", "to move quickly on foot"),
            (PartOfSpeech.NOUN, "a_jog", "a short period of running"),
        ),
    ),
    (
        "book",
        ("book", "books", "booked", "booking"),
        (
            (PartOfSpeech.NOUN, "volume", "a set of printed pages held together"),
            (PartOfSpeech.VERB, "reserve", "to arrange to have something later"),
        ),
    ),
    (
        "water",
        ("water", "waters", "watered", "watering"),
        ((PartOfSpeech.NOUN, "liquid", "the clear liquid that falls as rain"),),
    ),
    (
        "word",
        ("word", "words", "worded", "wording"),
        ((PartOfSpeech.NOUN, "unit_of_language", "a single unit of language"),),
    ),
    (
        "hello",
        ("hello", "hellos"),
        ((PartOfSpeech.OTHER, "greeting", "a word used to greet someone"),),
    ),
    (
        "house",
        ("house", "houses", "housed", "housing"),
        ((PartOfSpeech.NOUN, "building", "a building where people live"),),
    ),
    (
        "read",
        ("read", "reads", "reading"),
        ((PartOfSpeech.VERB, "look_at_words", "to look at and understand written words"),),
    ),
    (
        "write",
        ("write", "writes", "writing", "wrote", "written"),
        ((PartOfSpeech.VERB, "put_words_down", "to put words on paper or a screen"),),
    ),
    (
        "quick",
        ("quick", "quicker", "quickest"),
        ((PartOfSpeech.ADJECTIVE, "fast", "moving or happening fast"),),
    ),
    (
        "happy",
        ("happy", "happier", "happiest"),
        ((PartOfSpeech.ADJECTIVE, "glad", "feeling or showing pleasure"),),
    ),
    (
        "go",
        ("go", "goes", "going", "went", "gone"),
        ((PartOfSpeech.VERB, "move", "to move from one place to another"),),
    ),
    (
        "see",
        ("see", "sees", "seeing", "saw", "seen"),
        ((PartOfSpeech.VERB, "look", "to notice with your eyes"),),
    ),
    (
        "make",
        ("make", "makes", "making", "made"),
        ((PartOfSpeech.VERB, "create", "to create or produce something"),),
    ),
    (
        "good",
        ("good", "better", "best"),
        ((PartOfSpeech.ADJECTIVE, "fine", "of high quality or pleasant"),),
    ),
)


def build_default_inventory() -> SeededSenseInventory:
    """Build the seeded inventory the service ships with."""

    entries: dict[str, tuple[SenseRecord, ...]] = {}
    forms: dict[str, str] = {}
    for lemma, inflections, senses in _WORDS:
        entries[lemma] = tuple(
            SenseRecord(
                part_of_speech=part_of_speech,
                sense_label=sense_label,
                gloss_phrase=gloss_phrase,
                rank=rank,
            )
            for rank, (part_of_speech, sense_label, gloss_phrase) in enumerate(senses)
        )
        for form in inflections:
            forms[form] = lemma
    return SeededSenseInventory(entries=entries, forms=forms)
