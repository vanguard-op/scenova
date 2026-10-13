"""Runtime configuration for the model-serving layer.

Values are read from the environment declared in `.env.example` (the API key,
the request timeout, the retry count, the circuit breaker, and the internal
audience). Nothing secret is read from a repository file (NFR-024).

The two model pins, the decoding knobs, and the guardrail knobs below are
constants rather than environment variables: they are part of the pinned
behaviour the quality bar was measured on, so they change with the prompt
artifact, not per environment.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache
from typing import Literal

# The two versions the quality bar was measured on (architecture "Model Version
# & Fallback"): the gloss phrase is a text capability pinned to its text model
# and measured on NFR-050, and the clip is a video capability pinned to its video
# model and measured on NFR-051/NFR-053. Each pin is used only for the step it
# belongs to; a replacement is a new pin after a fresh evaluation, never a shared
# value. No other version is used.
PHRASE_MODEL_PIN = "gemini-3.5-flash-lite"
CLIP_MODEL_PIN = "gemini-omni-1.1-flash"
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"

# Pinned decoding: low temperature keeps the phrase concrete and common.
TEMPERATURE = 0.4
TOP_P = 0.9
MAX_OUTPUT_TOKENS = 32

# Pinned output handling: the settled bound is "seven words or fewer" (FEAT-004
# output contract, NFR-050's rubric). A longer candidate is rejected by the
# guardrail and regenerated, then replaced by the fallback.
MAX_PHRASE_WORDS = 7
MAX_PHRASE_CHARS = 120
REGENERATION_ATTEMPTS = 2
RETRY_BACKOFF_SECONDS = 0.25

# Word-clip generation is pinned as well. The output contract is a 360p clip no
# longer than four seconds (FEAT-005). The pinned video model produces clips of
# three to ten seconds, so the product's four-second cap makes the effective
# target range three to four seconds: a shorter request is raised to the model's
# three-second minimum rather than sent and rejected. Resolution is a constant,
# not a knob, because the card the clip plays in is fixed.
ClipResolution = Literal["360p"]
CLIP_TARGET_RESOLUTION: ClipResolution = "360p"
CLIP_MAX_DURATION_SECONDS = 4
CLIP_MIN_DURATION_SECONDS = 3
CLIP_MIME_TYPE = "video/mp4"
# The pinned video model generates native audio with every clip, so the stored
# asset carries an audio track. The reader hears it only when they turn sound on
# (clips are muted by default), so the clip view needs `hasAudio` to be true or
# it renders the clip unmuted.
CLIP_HAS_AUDIO = True
CLIP_STORAGE_PREFIX = "clips/"

# Video generation is a long-running provider operation. The Interactions API
# returns the finished clip in one call, but a clip that is still being worked
# on is polled to completion, bounded by one overall timeout.
DEFAULT_CLIP_VIDEO_TIMEOUT_SECONDS = 120.0
DEFAULT_CLIP_POLL_INTERVAL_SECONDS = 2.0


def _env_str(name: str, default: str) -> str:
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def _env_opt(name: str) -> str | None:
    value = os.environ.get(name)
    return value if value not in (None, "") else None


def _env_int(name: str, default: int) -> int:
    raw = _env_opt(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_float(name: str, default: float) -> float:
    raw = _env_opt(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


@dataclass(frozen=True, slots=True)
class Settings:
    """Immutable configuration resolved once at process start."""

    phrase_model_pin: str
    clip_model_pin: str
    gemini_api_key: str | None
    request_timeout_seconds: float
    max_attempts: int
    retry_backoff_seconds: float
    circuit_failure_threshold: int
    circuit_reset_seconds: float
    internal_audience: str
    regeneration_attempts: int
    max_phrase_words: int
    max_phrase_chars: int
    temperature: float
    top_p: float
    max_output_tokens: int
    clip_bucket: str
    clip_cdn_base_url: str
    clip_storage_prefix: str
    clip_target_resolution: ClipResolution
    clip_min_duration_seconds: int
    clip_max_duration_seconds: int
    clip_video_timeout_seconds: float
    clip_poll_interval_seconds: float
    clip_has_audio: bool


def load_settings() -> Settings:
    """Build settings from the environment, falling back to documented defaults."""

    return Settings(
        phrase_model_pin=PHRASE_MODEL_PIN,
        clip_model_pin=CLIP_MODEL_PIN,
        gemini_api_key=_env_opt("GEMINI_API_KEY"),
        request_timeout_seconds=_env_float("GEMINI_TIMEOUT_SECONDS", 30.0),
        max_attempts=_env_int("GEMINI_MAX_ATTEMPTS", 3),
        retry_backoff_seconds=RETRY_BACKOFF_SECONDS,
        circuit_failure_threshold=_env_int("CIRCUIT_BREAKER_FAILURE_THRESHOLD", 5),
        circuit_reset_seconds=_env_float("CIRCUIT_BREAKER_RESET_SECONDS", 60.0),
        internal_audience=_env_str("INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
        regeneration_attempts=REGENERATION_ATTEMPTS,
        max_phrase_words=MAX_PHRASE_WORDS,
        max_phrase_chars=MAX_PHRASE_CHARS,
        temperature=TEMPERATURE,
        top_p=TOP_P,
        max_output_tokens=MAX_OUTPUT_TOKENS,
        clip_bucket=_env_str("CLIP_BUCKET", ""),
        clip_cdn_base_url=_env_str("CLIP_CDN_BASE_URL", ""),
        clip_storage_prefix=CLIP_STORAGE_PREFIX,
        clip_target_resolution=CLIP_TARGET_RESOLUTION,
        clip_min_duration_seconds=CLIP_MIN_DURATION_SECONDS,
        clip_max_duration_seconds=CLIP_MAX_DURATION_SECONDS,
        clip_video_timeout_seconds=DEFAULT_CLIP_VIDEO_TIMEOUT_SECONDS,
        clip_poll_interval_seconds=DEFAULT_CLIP_POLL_INTERVAL_SECONDS,
        clip_has_audio=CLIP_HAS_AUDIO,
    )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return load_settings()
