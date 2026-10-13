"""Client request models for the gateway (C-001, C-002)."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict


class CreateLookupRequest(BaseModel):
    """The C-001 request body."""

    model_config = ConfigDict(extra="forbid")

    selection: str
    clientLookupId: str
    platform: Literal["android", "ios"]
    locale: str
    consentModelProcessing: bool
