"""Runtime configuration for the lookup service.

Values are read from the environment declared in `.env.example`; nothing secret
is read here (NFR-024).
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls (C-003, C-004,
# C-005). The gateway sends it when it calls the lookup service.
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"
DEFAULT_PIPELINE_PORT = "8082"
DEFAULT_LIBRARY_PORT = "8083"
DEFAULT_ENTITLEMENT_PORT = "8084"
# The lookup path must stay fast (NFR-002), so the enqueue call is bounded well
# below the reader-facing wait; a timeout is the reader's fallback, not a hang.
DEFAULT_PIPELINE_TIMEOUT_SECONDS = 5.0
# The shared-library read sits on the reader's fast path too. When it times out
# the lookup falls back to generation (FEAT-006 edge), so the wait stays short.
DEFAULT_LIBRARY_TIMEOUT_SECONDS = 3.0
# The allowance meter sits on the reader's fast path as well. A timeout is the
# grace path, not a block: the lookup proceeds and the client reconciles
# (NFR-011).
DEFAULT_ENTITLEMENT_TIMEOUT_SECONDS = 3.0
# The pinned video model the clip is generated against (architecture "Model
# Version & Fallback", D-018). The lookup service only carries the clip pin on a
# generation job (C-003); the gloss phrase pin belongs to the pipeline, which
# generates the phrase. The pin is a product-wide constant, so it is not a
# per-environment knob.
CLIP_MODEL_PIN = "gemini-omni-1.1-flash"
# Clips are capped at four seconds, so a generation targets the cap.
DEFAULT_GENERATION_TARGET_SECONDS = 4.0
# The `enable_phrase_clip` release flag (release.md "Rollout Phases & Feature
# Flags"): when off, a short phrase is not routed to the phrase path and falls
# back to the word path. It defaults on here so a missing variable never silently
# disables the feature; every environment supplies its rollout value (off until
# the phase rolls out) through `FLAG_ENABLE_PHRASE_CLIP`.
DEFAULT_ENABLE_PHRASE_CLIP = True


@dataclass(frozen=True)
class Settings:
    """Lookup service settings, resolved from the environment."""

    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    require_internal_auth: bool = True
    pipeline_base_url: str = f"http://127.0.0.1:{DEFAULT_PIPELINE_PORT}"
    pipeline_timeout_seconds: float = DEFAULT_PIPELINE_TIMEOUT_SECONDS
    library_base_url: str = f"http://127.0.0.1:{DEFAULT_LIBRARY_PORT}"
    library_timeout_seconds: float = DEFAULT_LIBRARY_TIMEOUT_SECONDS
    entitlement_base_url: str = f"http://127.0.0.1:{DEFAULT_ENTITLEMENT_PORT}"
    entitlement_timeout_seconds: float = DEFAULT_ENTITLEMENT_TIMEOUT_SECONDS
    clip_model_pin: str = CLIP_MODEL_PIN
    generation_target_duration_seconds: float = DEFAULT_GENERATION_TARGET_SECONDS
    # The phrase-clip kill switch; when off, a short phrase routes to the word path.
    enable_phrase_clip: bool = DEFAULT_ENABLE_PHRASE_CLIP

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        pipeline_base_url = _env_str(
            source,
            "PIPELINE_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'PIPELINE_PORT', DEFAULT_PIPELINE_PORT)}",
        )
        library_base_url = _env_str(
            source,
            "LIBRARY_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'LIBRARY_PORT', DEFAULT_LIBRARY_PORT)}",
        )
        entitlement_base_url = _env_str(
            source,
            "ENTITLEMENT_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'ENTITLEMENT_PORT', DEFAULT_ENTITLEMENT_PORT)}",
        )
        return cls(
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            require_internal_auth=_env_bool(source, "LOOKUP_REQUIRE_INTERNAL_AUTH", True),
            pipeline_base_url=pipeline_base_url,
            pipeline_timeout_seconds=_env_float(
                source, "LOOKUP_PIPELINE_TIMEOUT_SECONDS", DEFAULT_PIPELINE_TIMEOUT_SECONDS
            ),
            library_base_url=library_base_url,
            library_timeout_seconds=_env_float(
                source, "LOOKUP_LIBRARY_TIMEOUT_SECONDS", DEFAULT_LIBRARY_TIMEOUT_SECONDS
            ),
            entitlement_base_url=entitlement_base_url,
            entitlement_timeout_seconds=_env_float(
                source,
                "LOOKUP_ENTITLEMENT_TIMEOUT_SECONDS",
                DEFAULT_ENTITLEMENT_TIMEOUT_SECONDS,
            ),
            clip_model_pin=_env_str(source, "CLIP_MODEL_PIN", CLIP_MODEL_PIN),
            generation_target_duration_seconds=_env_float(
                source,
                "LOOKUP_GENERATION_TARGET_SECONDS",
                DEFAULT_GENERATION_TARGET_SECONDS,
            ),
            enable_phrase_clip=_env_bool(
                source, "FLAG_ENABLE_PHRASE_CLIP", DEFAULT_ENABLE_PHRASE_CLIP
            ),
        )


def _env_str(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name)
    return value if value not in (None, "") else default


def _env_bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value in (None, ""):
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


def _env_float(env: Mapping[str, str], name: str, default: float) -> float:
    raw = env.get(name)
    if raw in (None, ""):
        return default
    try:
        return float(raw)
    except ValueError:
        return default
