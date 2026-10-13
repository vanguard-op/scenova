"""Client request models for the gateway (C-001, C-002, C-007, C-008).

The gateway validates the request shape it routes, so a malformed body is a 400
before a service is called. For events it validates the envelope only: the
taxonomy and the personal-data scan stay with the analytics intake, which is
their single owner. For a push registration it validates the shape only: whether
the lookup exists and belongs to the caller stays with the notification service.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

# The contract's batch cap (`C-007`, at most fifty).
MAX_EVENT_BATCH_SIZE = 50


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
