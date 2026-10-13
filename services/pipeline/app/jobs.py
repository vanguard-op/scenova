"""Job, clip, and library records (schema "GenerationJob", "ClipAsset", "LibraryEntry").

The job record carries the library key (lemma, sense, part of speech) and the
target duration alongside the schema's own fields, because the pipeline needs
them to write a word clip to the shared library and to enforce the four-second
cap once the clip is produced. It also carries the correlation id the enqueue
arrived with, so a generation event ties back to the lookup that started it
(`analytics.md` "Error & Performance Monitoring").
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from .models import JobStatus, Kind, PartOfSpeech


@dataclass(frozen=True)
class ClipAsset:
    """A generated word clip stored centrally (schema "ClipAsset")."""

    id: str
    duration_seconds: float
    resolution: Literal["360p"]
    storage_key: str
    url: str
    has_audio: bool
    synth_id_watermark: bool
    created_at: str


@dataclass(frozen=True)
class LibraryEntry:
    """A shared library entry keyed by lemma and sense (schema "LibraryEntry")."""

    id: str
    lemma: str
    part_of_speech: PartOfSpeech
    sense_label: str
    gloss_phrase: str
    clip_asset_id: str
    status: Literal["active", "held", "retired"]
    source: Literal["seeded", "generated"]
    created_at: str
    updated_at: str


@dataclass(frozen=True)
class GenerationJob:
    """One asynchronous job that produces a clip for a lookup (schema "GenerationJob")."""

    id: str
    lookup_id: str
    kind: Kind
    lemma: str | None
    phrase: str
    sense_label: str
    part_of_speech: PartOfSpeech
    target_duration_seconds: float
    provider_model: str
    correlation_id: str
    status: JobStatus
    attempts: int
    cost_units: float
    created_at: str
    completed_at: str | None
