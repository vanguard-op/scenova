"""Wire models for the feedback service.

`POST /v1/feedback` is C-012 and `POST /v1/reports` is C-013: the client rates a
clip it saw or reports one that is wrong or offensive. The `user_id` is never a
field; the intake takes it from the authenticated token subject, so the client
sends no identity and the recorded rating belongs to the caller.

The records mirror the `schema.md` entities "Feedback" and "Report"; the review
queue the two feed is the curator console's operator surface (FEAT-015), whose
wire shapes are C-014 to C-016. A report opens a queue item and regenerates one
clip for the entry, held as the candidate the curator chooses between.
"""

from __future__ import annotations

from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field

# The contract's note bound (`C-013`, at most 300 characters).
MAX_REPORT_NOTE_LENGTH = 300
# The contract's curator-note bound (`C-016`, at most 500 characters).
MAX_ACTION_NOTES_LENGTH = 500


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
    state: ReportStatus


class AnonymizeRequest(BaseModel):
    """The internal anonymization seam's request: the deleted reader's subject."""

    model_config = ConfigDict(extra="forbid")

    subject: str


class AnonymizeResponse(BaseModel):
    """The internal anonymization seam's response: how many records were stripped."""

    model_config = ConfigDict(extra="forbid")

    anonymized: int


class EntryStatus(StrEnum):
    """Whether a library entry is served or retired (C-015, C-016).

    An entry under review keeps serving; its review state lives on its queue
    item, so there is no `held` status (FEAT-015).
    """

    ACTIVE = "active"
    RETIRED = "retired"


class ReviewState(StrEnum):
    """Where an entry sits in the curator's queue (C-014 `state`).

    `queued` awaits a curator; `actioned` is a recorded decision (a choice of
    clip or a retirement); `reviewed` is a phrase edit that regenerates the entry
    and leaves it under review for the curator to decide on.
    """

    QUEUED = "queued"
    REVIEWED = "reviewed"
    ACTIONED = "actioned"


class ModerationActionName(StrEnum):
    """What a curator did to an entry (schema "ModerationAction").

    `choose` makes a named clip the one served to every reader, `retire` stops
    serving the entry, and `edit_phrase` regenerates the entry from a new phrase.
    """

    CHOOSE = "choose"
    RETIRE = "retire"
    EDIT_PHRASE = "edit_phrase"


class ChosenClip(StrEnum):
    """Which clip a `choose` action makes the one served (C-016 `chosenClip`)."""

    SERVING = "serving"
    CANDIDATE = "candidate"


class QueueItem(BaseModel):
    """One entry awaiting review, as the queue lists it (C-014 `items`)."""

    model_config = ConfigDict(extra="forbid")

    entryId: str
    lemma: str
    senseLabel: str
    # The reason the entry was queued: the newest report's reason, or the
    # feedback-threshold flag when repeated negative feedback queued it.
    reason: str
    queuedAt: str
    state: ReviewState


class QueueResponse(BaseModel):
    """The C-014 200 response: a page of the queue and the open-item count."""

    model_config = ConfigDict(extra="forbid")

    items: list[QueueItem]
    openCount: int
    page: int
    pageCount: int


class ReviewClip(BaseModel):
    """The clip behind a queued entry (C-015 `entry.clip`)."""

    model_config = ConfigDict(extra="forbid")

    url: str
    durationSeconds: float
    resolution: str
    hasAudio: bool


class ReviewEntry(BaseModel):
    """The library entry a curator reviews (C-015 `entry`)."""

    model_config = ConfigDict(extra="forbid")

    entryId: str
    lemma: str
    senseLabel: str
    glossPhrase: str
    status: EntryStatus
    clip: ReviewClip


class EntryReport(BaseModel):
    """One reader report against a queued entry (C-015 `reports`)."""

    model_config = ConfigDict(extra="forbid")

    reportId: str
    reason: str
    note: str | None
    createdAt: str


class EntryFeedback(BaseModel):
    """One negative rating against a queued entry (C-015 `feedback`)."""

    model_config = ConfigDict(extra="forbid")

    rating: Rating
    createdAt: str


class EntryDetailResponse(BaseModel):
    """The C-015 200 response: the entry, its candidate, its evidence, and state."""

    model_config = ConfigDict(extra="forbid")

    entry: ReviewEntry
    # The clip regenerated for the reporting reader, held for the curator; null
    # when no report has produced one (FEAT-011).
    candidate: ReviewClip | None
    reports: list[EntryReport]
    feedback: list[EntryFeedback]
    state: ReviewState


class ActionRequest(BaseModel):
    """The C-016 request body."""

    model_config = ConfigDict(extra="forbid")

    action: ModerationActionName
    # Which clip a `choose` makes the one served: the clip already serving, or
    # the candidate regenerated for the reporting reader.
    chosenClip: ChosenClip | None = None
    phrase: str | None = Field(default=None, max_length=60)
    notes: str | None = Field(default=None, max_length=MAX_ACTION_NOTES_LENGTH)
    expectedState: ReviewState


class ActionResponse(BaseModel):
    """The C-016 200 response: the recorded action and the entry's new state."""

    model_config = ConfigDict(extra="forbid")

    actionId: str
    entryId: str
    status: EntryStatus
    state: ReviewState
