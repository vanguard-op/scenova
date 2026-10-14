"""Wire models for the feedback service.

`POST /v1/feedback` is C-012 and `POST /v1/reports` is C-013: the client rates a
clip it saw or reports one that is wrong or offensive. The `user_id` is never a
field; the intake takes it from the authenticated token subject, so the client
sends no identity and the recorded rating belongs to the caller.

The records mirror the `schema.md` entities "Feedback" and "Report"; the review
queue the two feed is internal and has no wire shape until the curator console
(FEAT-015) gives it one.
"""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field

# The contract's note bound (`C-013`, at most 300 characters).
MAX_REPORT_NOTE_LENGTH = 300


class Rating(StrEnum):
    """The reader's rating of a served clip (schema "Feedback")."""

    HELPFUL = "helpful"
    NOT_HELPFUL = "not_helpful"
    WRONG = "wrong"


class ReportReason(StrEnum):
    """Why the reader reported a clip (schema "Report")."""

    WRONG_MEANING = "wrong_meaning"
    OFFENSIVE = "offensive"
    LOW_QUALITY = "low_quality"
    OTHER = "other"


class ReportStatus(StrEnum):
    """The report's review state (schema "Report")."""

    QUEUED = "queued"
    REVIEWED = "reviewed"
    ACTIONED = "actioned"


class LookupKind(StrEnum):
    """Whether the lookup was for a word or a phrase (C-001 / C-002 `kind`)."""

    WORD = "word"
    PHRASE = "phrase"


class LookupStatus(StrEnum):
    """How the reader's lookup resolved (C-001 / C-002 `status`)."""

    SERVED = "served"
    GENERATING = "generating"
    FALLBACK = "fallback"
    DENIED = "denied"
    EMPTY = "empty"


class FeedbackRequest(BaseModel):
    """The C-012 request body."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    rating: Rating
    clientFeedbackId: str


class FeedbackResponse(BaseModel):
    """The C-012 202 response: whether the rating was recorded."""

    model_config = ConfigDict(extra="forbid")

    recorded: bool


class ReportRequest(BaseModel):
    """The C-013 request body."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    reason: ReportReason
    note: str | None = Field(default=None, max_length=MAX_REPORT_NOTE_LENGTH)
    clientReportId: str


class ReportResponse(BaseModel):
    """The C-013 202 response: the queued report and its review state."""

    model_config = ConfigDict(extra="forbid")

    reportId: str
    status: ReportStatus
