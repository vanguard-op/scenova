"""Word-clip generation service (FEAT-005).

Orchestrates one model-backed clip: render the versioned prompt, ask the
provider for a clip at the pinned duration and resolution, write the result to
object storage, and describe it for the generation pipeline. Provider refusal,
timeout, and unavailability are left to the caller (the router) to map onto the
contract's 422, 504, and 503.
"""

from __future__ import annotations

import math
import uuid
from dataclasses import dataclass

from ..config import CLIP_MIME_TYPE, ClipResolution, Settings
from ..prompt import PromptTemplate
from ..provider import ClipModel
from .store import ClipStore


@dataclass(frozen=True, slots=True)
class ClipRequest:
    """A request to turn one gloss phrase into a clip (C-005 input)."""

    phrase: str
    target_duration_seconds: float
    model_pin: str


@dataclass(frozen=True, slots=True)
class ClipResult:
    """The stored clip and its output contract (C-005 output)."""

    clip_id: str
    storage_key: str
    url: str
    duration_seconds: float
    resolution: ClipResolution
    has_audio: bool
    synth_id_watermark: bool


class ClipService:
    """Turns a gloss phrase into a short, 360p clip."""

    def __init__(
        self,
        *,
        model: ClipModel,
        store: ClipStore,
        prompt: PromptTemplate,
        settings: Settings,
    ) -> None:
        self._model = model
        self._store = store
        self._prompt = prompt
        self._settings = settings

    def _duration_seconds(self, requested: float) -> int:
        """Clamp the target to the pinned model's one-to-four-second range.

        The provider takes whole seconds and will not make a clip shorter than
        three seconds, so the target is rounded up (never under the requested
        length) and then held between the model's minimum and the product's
        four-second cap.
        """

        ceiling = math.ceil(requested)
        return max(
            self._settings.clip_min_duration_seconds,
            min(self._settings.clip_max_duration_seconds, ceiling),
        )

    async def generate(self, request: ClipRequest) -> ClipResult:
        duration = self._duration_seconds(request.target_duration_seconds)
        system, user = self._prompt.render(phrase=request.phrase)
        model_pin = request.model_pin or self._settings.clip_model_pin

        data = await self._model.generate(
            system=system,
            user=user,
            model_pin=model_pin,
            duration_seconds=duration,
            resolution=self._settings.clip_target_resolution,
        )

        clip_id = uuid.uuid4().hex
        storage_key = f"{self._settings.clip_storage_prefix}{clip_id}.mp4"
        stored = await self._store.put(
            storage_key=storage_key,
            data=data,
            content_type=CLIP_MIME_TYPE,
        )
        return ClipResult(
            clip_id=clip_id,
            storage_key=stored.storage_key,
            url=stored.url,
            duration_seconds=float(duration),
            resolution=self._settings.clip_target_resolution,
            has_audio=self._settings.clip_has_audio,
            # The pinned provider watermarks generated video with SynthID.
            synth_id_watermark=True,
        )
