"""Wire models for the generation pipeline (C-003).

The request and response bodies are the C-003 contract exactly. The job status
enum is wider than the response allows: a job moves through queued and running
to succeeded, failed, or declined, but the enqueue response only ever reports
the first two.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class Kind(StrEnum):
    """Whether the job is for a word or a phrase."""

    WORD = "word"
    PHRASE = "phrase"


class PartOfSpeech(StrEnum):
    """Part of speech for a sense, matching the LibraryEntry schema."""

    NOUN = "noun"
    VERB = "verb"
    ADJECTIVE = "adjective"
    ADVERB = "adverb"
    PREPOSITION = "preposition"
    OTHER = "other"


class JobStatus(StrEnum):
    """Job state, matching the GenerationJob schema."""

    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    DECLINED = "declined"


class CreateJobRequest(BaseModel):
    """The C-003 request body."""

    model_config = ConfigDict(extra="forbid")

    jobId: str
    lookupId: str
    kind: Kind
    lemma: str | None = None
    phrase: str
    senseLabel: str
    partOfSpeech: PartOfSpeech
    targetDurationSeconds: float
    modelPin: str
    attempt: int = Field(default=0, ge=0)


class CreateJobResponse(BaseModel):
    """The C-003 202 response body."""

    model_config = ConfigDict(extra="forbid")

    jobId: str
    status: Literal["queued", "running"]


class JobStatusResponse(BaseModel):
    """The C-006 response body: a job's state, including its terminal outcomes."""

    model_config = ConfigDict(extra="forbid")

    jobId: str
    lookupId: str
    status: JobStatus
