"""Client request models for the gateway (C-001, C-002, C-007, C-008, C-012, C-013, C-020).

The gateway validates the request shape it routes, so a malformed body is a 400
before a service is called. For events it validates the envelope only: the
taxonomy and the personal-data scan stay with the analytics intake, which is
their single owner. For a push registration it validates the shape only: whether
the lookup exists and belongs to the caller stays with the notification service.
For a rating or a report it validates the shape only: the lookup's ownership, the
served clip, and the review queue stay with the feedback service. For an account
update it validates the shape only: whether at least one field was given and
whether the locale is one the product offers stay with the entitlement service.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

# The contract's batch cap (`C-007`, at most fifty).
MAX_EVENT_BATCH_SIZE = 50
# The contract's note bound (`C-013`, at most 300 characters).
MAX_REPORT_NOTE_LENGTH = 300


class CreateLookupRequest(BaseModel):
    """The C-001 request body."""

    model_config = ConfigDict(extra="forbid")

    selection: str
    clientLookupId: str
    platform: Literal["android", "ios"]
    locale: str
    consentModelProcessing: bool


class EventIn(BaseModel):
    """One event in a C-007 batch."""

    model_config = ConfigDict(extra="forbid")

    eventId: str
    name: str
    occurredAt: str
    anonymousId: str
    sessionId: str
    platform: Literal["android", "ios"]
    appVersion: str
    locale: str
    properties: dict[str, Any] = Field(default_factory=dict)


class IngestEventsRequest(BaseModel):
    """The C-007 request body."""

    model_config = ConfigDict(extra="forbid")

    events: list[EventIn] = Field(default_factory=list, max_length=MAX_EVENT_BATCH_SIZE)


class RegisterPushRequest(BaseModel):
    """The C-008 request body.

    `lookupId` is required: a registration is for a lookup the reader is waiting
    on, so the token is bound to it and a ready notice can find its way back.
    """

    model_config = ConfigDict(extra="forbid")

    token: str
    platform: Literal["android", "ios"]
    lookupId: str


class FeedbackRequest(BaseModel):
    """The C-012 request body."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    rating: Literal["helpful", "not_helpful", "wrong"]
    clientFeedbackId: str


class ReportRequest(BaseModel):
    """The C-013 request body."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    reason: Literal["wrong_meaning", "offensive", "low_quality", "other"]
    note: str | None = Field(default=None, max_length=MAX_REPORT_NOTE_LENGTH)
    clientReportId: str


class AccountUpdateRequest(BaseModel):
    """The C-020 request body.

    Both fields are optional in shape; the contract's rule that at least one is
    given is enforced by the entitlement service, so the 400 has one owner.
    """

    model_config = ConfigDict(extra="forbid")

    consentModelProcessing: bool | None = None
    locale: str | None = None
