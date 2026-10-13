"""The two pinned model versions the generation path depends on (schema "ModelPin").

The generation path pins two models and no others (architecture "Model Version &
Fallback"): the text model that produces the gloss phrase and the video model that
produces the clip. A finished job records both, so a clip can be attributed to the
exact model pair that produced it and a model upgrade can be traced to the jobs it
affected.

A pin names the provider model, the version the quality bar was measured against,
the modality of its output, when it was pinned, and the state of the last
golden-set evaluation. For Gemini the provider identifier is itself versioned, so
the identifier and the version carry the same string; they stay separate fields
because a provider that versions a stable identifier would use them differently.
The versions are configuration, not code: pinning a qualified replacement is a
deploy, and the defaults are the versions the phase's quality bars were measured
against. The evaluation state is left `unevaluated` here; the quality-bar run owns
it and records it when the pipeline reads a persisted pin store.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from .config import Settings

Modality = Literal["text", "video"]
QualityStatus = Literal["passing", "failing", "unevaluated"]


@dataclass(frozen=True)
class ModelPin:
    """One pinned model version and the state of its quality bar (schema "ModelPin")."""

    id: str
    model_id: str
    modality: Modality
    version: str
    pinned_at: str
    quality_status: QualityStatus
    last_evaluated_at: str | None = None


@dataclass(frozen=True)
class ModelPins:
    """The two pins the generation path uses, one per model-backed capability."""

    phrase: ModelPin
    clip: ModelPin

    @classmethod
    def from_settings(cls, settings: Settings) -> ModelPins:
        """Resolve the two pins from configuration.

        A pin the pipeline has not seen a golden-set evaluation for is
        `unevaluated`, never assumed `passing`: the quality-bar run owns that
        verdict, and a capability whose evaluation falls below its bar blocks
        release of the generation path.
        """

        return cls(
            phrase=ModelPin(
                id="pin_phrase",
                model_id=settings.phrase_model_pin,
                modality="text",
                version=settings.phrase_model_pin,
                pinned_at=settings.phrase_model_pinned_at,
                quality_status="unevaluated",
            ),
            clip=ModelPin(
                id="pin_clip",
                model_id=settings.clip_model_pin,
                modality="video",
                version=settings.clip_model_pin,
                pinned_at=settings.clip_model_pinned_at,
                quality_status="unevaluated",
            ),
        )
