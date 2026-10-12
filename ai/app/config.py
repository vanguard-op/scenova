"""Runtime configuration for the model-serving layer.

Values are read from the environment declared in `.env.example` (the model pin,
the API key, the request timeout, the retry count, the circuit breaker, and the
internal audience). Nothing secret is read from a repository file (NFR-024).

The decoding and guardrail knobs below are constants rather than environment
variables: they are part of the pinned behaviour the quality bar was measured
on, so they change with the prompt artifact, not per environment.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache

# The version the quality bar was measured on (architecture "Model Version &
# Fallback"); no other version is used unless a fresh evaluation pins one.
DEFAULT_MODEL_PIN = "gemini-omni-1.1-flash"
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"

# Pinned decoding: low temperature keeps the phrase concrete and common.
TEMPERATURE = 0.4
TOP_P = 0.9
MAX_OUTPUT_TOKENS = 32

# Pinned output handling: "fewer than seven words" from the capability contract.
MAX_PHRASE_WORDS = 6
MAX_PHRASE_CHARS = 120
REGENERATION_ATTEMPTS = 2
RETRY_BACKOFF_SECONDS = 0.25


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

    model_pin: str
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


def load_settings() -> Settings:
    """Build settings from the environment, falling back to documented defaults."""

    return Settings(
        model_pin=_env_str("GEMINI_MODEL", DEFAULT_MODEL_PIN),
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
    )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return load_settings()
