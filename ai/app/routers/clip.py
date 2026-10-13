"""POST /internal/model/clip — word-clip generation (C-005, FEAT-005)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field, field_validator

from ..auth import require_internal_caller
from ..clip.service import ClipRequest, ClipService
from ..clip.store import ClipStorageError
from ..config import ClipResolution
from ..dependencies import get_clip_service
from ..errors import (
    ProviderDeclinedError,
    ProviderTimeoutError,
    ProviderUnavailableError,
    StorageUnavailableError,
)
from ..provider import ProviderRefusal, ProviderTimeout, ProviderUnavailable

router = APIRouter(tags=["model"])


class ClipRequestBody(BaseModel):
    """C-005 request: the gloss phrase and the clip's target duration."""

    model_config = ConfigDict(extra="forbid")

    phrase: str = Field(min_length=1)
    targetDurationSeconds: float = Field(le=4)
    modelPin: str = Field(min_length=1)

    @field_validator("phrase")
    @classmethod
    def _phrase_is_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("phrase must not be blank")
        return value


class ClipResponseBody(BaseModel):
    """C-005 response: the stored clip and its output contract."""

    clipId: str
    storageKey: str
    url: str
    durationSeconds: float
    resolution: ClipResolution
    hasAudio: bool
    synthIdWatermark: bool


@router.post("/internal/model/clip", status_code=201, response_model=ClipResponseBody)
async def generate_clip(
    body: ClipRequestBody,
    service: Annotated[ClipService, Depends(get_clip_service)],
    _caller: Annotated[None, Depends(require_internal_caller)],
) -> ClipResponseBody:
    try:
        result = await service.generate(
            ClipRequest(
                phrase=body.phrase,
                target_duration_seconds=body.targetDurationSeconds,
                model_pin=body.modelPin,
            )
        )
    except ProviderRefusal as exc:
        # The provider declined the phrase: no clip is produced or stored.
        raise ProviderDeclinedError("The model provider declined to generate a clip.") from exc
    except ProviderTimeout as exc:
        raise ProviderTimeoutError("The model provider did not finish the clip in time.") from exc
    except ProviderUnavailable as exc:
        raise ProviderUnavailableError("The model provider is unavailable.") from exc
    except ClipStorageError as exc:
        # A clip that cannot be stored has nothing to serve, so the pipeline
        # takes the same fallback path as a provider failure.
        raise StorageUnavailableError("The clip could not be stored.") from exc

    return ClipResponseBody(
        clipId=result.clip_id,
        storageKey=result.storage_key,
        url=result.url,
        durationSeconds=result.duration_seconds,
        resolution=result.resolution,
        hasAudio=result.has_audio,
        synthIdWatermark=result.synth_id_watermark,
    )
