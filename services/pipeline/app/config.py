"""Runtime configuration for the generation pipeline.

Every value has a documented default, so the service starts without an
environment; nothing secret is read here (NFR-024). The clip's duration range is
a constant rather than an environment variable: it is part of the pinned output
contract the quality bar was measured on, so it changes with the feature, not per
environment.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls (C-003, C-004,
# C-005). The lookup service sends it when it enqueues a generation job.
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"
DEFAULT_MODEL_PORT = "8090"
DEFAULT_LIBRARY_PORT = "8083"
DEFAULT_NOTIFICATION_PORT = "8087"
# The two model versions the generation path pins and no others (architecture
# "Model Version & Fallback", D-018): the text model that produces the gloss
# phrase and the video model that produces the clip. Both are pinned so each
# quality bar has an anchor, so they are constants, not per-environment knobs.
PHRASE_MODEL_PIN = "gemini-3.5-flash-lite"
CLIP_MODEL_PIN = "gemini-omni-1.1-flash"
# When the two pins were settled. A fresh golden-set evaluation that pins a
# qualified replacement moves this date with the new version.
DEFAULT_PINNED_AT = "2026-10-12T00:00:00+00:00"
# Clip generation is a long-running job (NFR-003, NFR-004), so the internal
# client waits far longer than the lookup path does.
DEFAULT_MODEL_TIMEOUT_SECONDS = 120.0
# The gloss phrase is a short text call. The model layer bounds it with its own
# request timeout and answers with its fallback, so the pipeline's outer wait is
# a little longer than that rather than the clip's long wait.
DEFAULT_PHRASE_TIMEOUT_SECONDS = 40.0
# The shared-library write runs after the clip is produced, off the reader's
# path. When it cannot be accepted the clip is still delivered, so a short wait
# and a few attempts are enough to ride out a blip without holding the job open.
DEFAULT_LIBRARY_TIMEOUT_SECONDS = 5.0
DEFAULT_LIBRARY_STORE_ATTEMPTS = 3
DEFAULT_LIBRARY_STORE_RETRY_DELAY_SECONDS = 0.25
# The clip-ready notice to the notification service runs after the clip is
# produced, off the reader's path. When it cannot be sent the clip is still
# delivered, so a short wait is enough to report it without holding the job open.
DEFAULT_NOTIFICATION_TIMEOUT_SECONDS = 5.0
# The pinned video model produces clips of three to four seconds, so a clip
# outside that range is withheld: shorter than three is not the output the model
# was pinned to produce, and longer than four is past the product's cap. Both
# bounds are part of the pinned output contract, not per-environment knobs.
CLIP_MIN_DURATION_SECONDS = 3.0
CLIP_MAX_DURATION_SECONDS = 4.0
# The `enable_generation` release flag (release.md "Rollout Phases & Feature
# Flags"): the runtime kill switch that stops new generation while the shared
# library and device history keep serving. It defaults on here so a missing
# variable never silently disables the feature; every environment supplies its
# rollout value (off until the phase rolls out) through `FLAG_ENABLE_GENERATION`.
DEFAULT_ENABLE_GENERATION = True
# The `enable_phrase_clip` release flag (release.md "Rollout Phases & Feature
# Flags"): the runtime kill switch that disables phrase clips, so a phrase job
# stops without a clip and the lookup falls back to the word path. Like the
# generation switch it defaults on here, so a missing variable never silently
# disables the feature; every environment supplies its rollout value through
# `FLAG_ENABLE_PHRASE_CLIP`.
DEFAULT_ENABLE_PHRASE_CLIP = True


@dataclass(frozen=True)
class Settings:
    """Generation pipeline settings, resolved from the environment."""

    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    require_internal_auth: bool = True
    model_base_url: str = f"http://127.0.0.1:{DEFAULT_MODEL_PORT}"
    model_timeout_seconds: float = DEFAULT_MODEL_TIMEOUT_SECONDS
    phrase_timeout_seconds: float = DEFAULT_PHRASE_TIMEOUT_SECONDS
    library_base_url: str = f"http://127.0.0.1:{DEFAULT_LIBRARY_PORT}"
    library_timeout_seconds: float = DEFAULT_LIBRARY_TIMEOUT_SECONDS
    library_store_attempts: int = DEFAULT_LIBRARY_STORE_ATTEMPTS
    library_store_retry_delay_seconds: float = DEFAULT_LIBRARY_STORE_RETRY_DELAY_SECONDS
    notification_base_url: str = f"http://127.0.0.1:{DEFAULT_NOTIFICATION_PORT}"
    notification_timeout_seconds: float = DEFAULT_NOTIFICATION_TIMEOUT_SECONDS
    clip_min_duration_seconds: float = CLIP_MIN_DURATION_SECONDS
    clip_max_duration_seconds: float = CLIP_MAX_DURATION_SECONDS
    # The two pinned model versions the generation path records on every job.
    phrase_model_pin: str = PHRASE_MODEL_PIN
    clip_model_pin: str = CLIP_MODEL_PIN
    phrase_model_pinned_at: str = DEFAULT_PINNED_AT
    clip_model_pinned_at: str = DEFAULT_PINNED_AT
    # A generation-cost ceiling, in provider clip calls; 0 means no ceiling.
    generation_budget_units: float = 0.0
    # The generation kill switch; when off, a job stops before any provider call.
    enable_generation: bool = DEFAULT_ENABLE_GENERATION
    # The phrase-clip kill switch; when off, a phrase job stops before any provider call.
    enable_phrase_clip: bool = DEFAULT_ENABLE_PHRASE_CLIP

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        model_base_url = _env_str(
            source,
            "MODEL_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'MODEL_PORT', DEFAULT_MODEL_PORT)}",
        )
        library_base_url = _env_str(
            source,
            "LIBRARY_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'LIBRARY_PORT', DEFAULT_LIBRARY_PORT)}",
        )
        notification_base_url = _env_str(
            source,
            "NOTIFICATION_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'NOTIFICATION_PORT', DEFAULT_NOTIFICATION_PORT)}",
        )
        return cls(
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            require_internal_auth=_env_bool(source, "PIPELINE_REQUIRE_INTERNAL_AUTH", True),
            model_base_url=model_base_url,
            model_timeout_seconds=_env_float(
                source, "PIPELINE_MODEL_TIMEOUT_SECONDS", DEFAULT_MODEL_TIMEOUT_SECONDS
            ),
            phrase_timeout_seconds=_env_float(
                source, "PIPELINE_PHRASE_TIMEOUT_SECONDS", DEFAULT_PHRASE_TIMEOUT_SECONDS
            ),
            library_base_url=library_base_url,
            library_timeout_seconds=_env_float(
                source, "PIPELINE_LIBRARY_TIMEOUT_SECONDS", DEFAULT_LIBRARY_TIMEOUT_SECONDS
            ),
            library_store_attempts=_env_int(
                source, "PIPELINE_LIBRARY_STORE_ATTEMPTS", DEFAULT_LIBRARY_STORE_ATTEMPTS
            ),
            library_store_retry_delay_seconds=_env_float(
                source,
                "PIPELINE_LIBRARY_STORE_RETRY_DELAY_SECONDS",
                DEFAULT_LIBRARY_STORE_RETRY_DELAY_SECONDS,
            ),
            notification_base_url=notification_base_url,
            notification_timeout_seconds=_env_float(
                source,
                "PIPELINE_NOTIFICATION_TIMEOUT_SECONDS",
                DEFAULT_NOTIFICATION_TIMEOUT_SECONDS,
            ),
            phrase_model_pin=_env_str(source, "PHRASE_MODEL_PIN", PHRASE_MODEL_PIN),
            clip_model_pin=_env_str(source, "CLIP_MODEL_PIN", CLIP_MODEL_PIN),
            phrase_model_pinned_at=_env_str(source, "PHRASE_MODEL_PINNED_AT", DEFAULT_PINNED_AT),
            clip_model_pinned_at=_env_str(source, "CLIP_MODEL_PINNED_AT", DEFAULT_PINNED_AT),
            generation_budget_units=_env_float(source, "PIPELINE_GENERATION_BUDGET_UNITS", 0.0),
            enable_generation=_env_bool(
                source, "FLAG_ENABLE_GENERATION", DEFAULT_ENABLE_GENERATION
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


def _env_int(env: Mapping[str, str], name: str, default: int) -> int:
    raw = env.get(name)
    if raw in (None, ""):
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_float(env: Mapping[str, str], name: str, default: float) -> float:
    raw = env.get(name)
    if raw in (None, ""):
        return default
    try:
        return float(raw)
    except ValueError:
        return default
