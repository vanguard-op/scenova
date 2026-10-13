"""Wire models for the notification service.

`POST /v1/push-registrations` is C-008: the client hands over a platform push
token and the lookup it is waiting on, and the service records it. The clip-ready
ingest is the internal call the generation pipeline makes when a job finishes
(architecture "Notification Service"); it carries the identifiers and the clip
the library already holds, never the word or phrase, so nothing about the
reader's selection reaches the push provider.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class Platform(StrEnum):
    """The reader's platform, as `push-registrations` takes it (C-008)."""

    ANDROID = "android"
    IOS = "ios"


class ClipDescriptor(BaseModel):
    """The finished clip the pipeline reports, mirroring the C-005 clip shape.

    The word and phrase are deliberately absent: the clip and its lookup are
    enough to open the view, and the reader's selection never travels with a
    notice.
    """

    model_config = ConfigDict(extra="forbid")

    clipId: str
    storageKey: str
    url: str
    durationSeconds: float = Field(gt=0, le=4)
    resolution: Literal["360p"] = "360p"
    hasAudio: bool
    synthIdWatermark: bool


class RegisterRequest(BaseModel):
    """The C-008 request body.

    The `user_id` is not a field: the intake takes it from the authenticated
    token subject, so the client never sends an identity.
    """

    model_config = ConfigDict(extra="forbid")

    token: str
    platform: Platform
    lookupId: str


class RegisterResponse(BaseModel):
    """The C-008 202 response: whether a notice will be delivered for the lookup."""

    model_config = ConfigDict(extra="forbid")

    registered: bool


class ClipReadyRequest(BaseModel):
    """The internal clip-ready ingest the generation pipeline calls."""

    model_config = ConfigDict(extra="forbid")

    lookupId: str
    jobId: str
    clip: ClipDescriptor


class ClipReadyResponse(BaseModel):
    """The ingest acknowledgement: how many notices were accepted for delivery."""

    model_config = ConfigDict(extra="forbid")

    queued: int
