"""Runtime configuration for the feedback service.

Values are read from the environment declared in `.env.example`; secrets are
never read from a repository file (NFR-024). Every value has a documented
default, so the service starts without an environment.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls. The feedback
# service sends it when it holds a library entry after a report (C-011).
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"
DEFAULT_LOOKUP_PORT = "8081"
DEFAULT_LIBRARY_PORT = "8083"
DEFAULT_PIPELINE_PORT = "8082"
# The intake throttle the contract puts at the gateway (C-012, C-013, 429). The
# service applies the same fixed window as its own defence when it is addressed
# directly, so a flood is refused either way.
DEFAULT_RATE_LIMIT_PER_MINUTE = 120
DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 60
# A rating and a report both confirm the lookup they are about against its owner
# (C-012, C-013). The confirmation is not on the reader's fast path, so the wait
# stays short.
DEFAULT_LOOKUP_TIMEOUT_SECONDS = 3.0
# Holding a reported entry is a short internal call to the library (C-011). When
# it cannot be made the intake reports the feedback store as unavailable, so the
# client retries; the wait stays short too.
DEFAULT_LIBRARY_TIMEOUT_SECONDS = 3.0
# How many readers whose latest rating of one entry is negative before that entry
# is queued for review (FEAT-010). The docs leave the value to the build, so it
# is a tunable here rather than a magic number in the service.
DEFAULT_NEGATIVE_FEEDBACK_THRESHOLD = 3
# A curator's replace or edit_phrase regenerates the entry through the generation
# pipeline (C-016). The hand-off is off the curator's path, so the wait stays
# short and the failure maps to the review service being unavailable.
DEFAULT_PIPELINE_TIMEOUT_SECONDS = 5.0
# The pinned video model the regeneration job names (C-003 `modelPin`), the same
# pin the generation path uses.
DEFAULT_CLIP_MODEL_PIN = "gemini-omni-1.1-flash"


@dataclass(frozen=True)
class Settings:
    """Feedback settings, resolved from the environment."""

    auth_mode: str = "dev"
    firebase_project_id: str | None = None
    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    # The internal anonymization seam (a deleted reader's feedback and reports)
    # is a service-to-service call; a direct caller must assert the audience
    # (nfr.md "Privacy & Compliance").
    require_internal_auth: bool = True
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    # The interactive schema (Swagger UI, ReDoc, OpenAPI) is a development aid,
    # never a published surface (nfr.md "Security"); `from_env` serves it only
    # for local development, and `DOCS_ENABLED` overrides that.
    docs_enabled: bool = False
    lookup_base_url: str = f"http://127.0.0.1:{DEFAULT_LOOKUP_PORT}"
    lookup_timeout_seconds: float = DEFAULT_LOOKUP_TIMEOUT_SECONDS
    library_base_url: str = f"http://127.0.0.1:{DEFAULT_LIBRARY_PORT}"
    library_timeout_seconds: float = DEFAULT_LIBRARY_TIMEOUT_SECONDS
    pipeline_base_url: str = f"http://127.0.0.1:{DEFAULT_PIPELINE_PORT}"
    pipeline_timeout_seconds: float = DEFAULT_PIPELINE_TIMEOUT_SECONDS
    clip_model_pin: str = DEFAULT_CLIP_MODEL_PIN
    rate_limit_per_minute: int = DEFAULT_RATE_LIMIT_PER_MINUTE
    rate_limit_window_seconds: int = DEFAULT_RATE_LIMIT_WINDOW_SECONDS
    negative_feedback_threshold: int = DEFAULT_NEGATIVE_FEEDBACK_THRESHOLD
    # The primary database the feedback, report, and review records live in
    # (architecture.md "Primary Database"). Empty resolves to the in-memory store,
    # which the unit tests and a bare local run use; every deployed environment
    # supplies it.
    database_url: str | None = None

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        environment = _env_str(source, "ENVIRONMENT", "dev")
        default_auth_mode = "firebase" if environment == "prod" else "dev"
        lookup_base_url = _env_str(
            source,
            "LOOKUP_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'LOOKUP_PORT', DEFAULT_LOOKUP_PORT)}",
        )
        library_base_url = _env_str(
            source,
            "LIBRARY_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'LIBRARY_PORT', DEFAULT_LIBRARY_PORT)}",
        )
        pipeline_base_url = _env_str(
            source,
            "PIPELINE_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'PIPELINE_PORT', DEFAULT_PIPELINE_PORT)}",
        )
        return cls(
            auth_mode=_env_str(source, "AUTH_MODE", default_auth_mode),
            firebase_project_id=_env_opt(source, "FIREBASE_PROJECT_ID"),
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            require_internal_auth=_env_bool(source, "FEEDBACK_REQUIRE_INTERNAL_AUTH", True),
            docs_enabled=_env_bool(source, "DOCS_ENABLED", environment == "dev"),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            lookup_base_url=lookup_base_url,
            lookup_timeout_seconds=_env_float(
                source, "FEEDBACK_LOOKUP_TIMEOUT_SECONDS", DEFAULT_LOOKUP_TIMEOUT_SECONDS
            ),
            library_base_url=library_base_url,
            library_timeout_seconds=_env_float(
                source, "FEEDBACK_LIBRARY_TIMEOUT_SECONDS", DEFAULT_LIBRARY_TIMEOUT_SECONDS
            ),
            pipeline_base_url=pipeline_base_url,
            pipeline_timeout_seconds=_env_float(
                source, "FEEDBACK_PIPELINE_TIMEOUT_SECONDS", DEFAULT_PIPELINE_TIMEOUT_SECONDS
            ),
            clip_model_pin=_env_str(source, "CLIP_MODEL_PIN", DEFAULT_CLIP_MODEL_PIN),
            rate_limit_per_minute=_env_int(
                source, "FEEDBACK_RATE_LIMIT_PER_MINUTE", DEFAULT_RATE_LIMIT_PER_MINUTE
            ),
            rate_limit_window_seconds=_env_int(
                source, "FEEDBACK_RATE_LIMIT_WINDOW_SECONDS", DEFAULT_RATE_LIMIT_WINDOW_SECONDS
            ),
            negative_feedback_threshold=_env_int(
                source,
                "FEEDBACK_NEGATIVE_THRESHOLD",
                DEFAULT_NEGATIVE_FEEDBACK_THRESHOLD,
            ),
            database_url=_env_opt(source, "DATABASE_URL"),
        )


def _env_bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value in (None, ""):
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}


def _env_str(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name)
    return value if value not in (None, "") else default


def _env_opt(env: Mapping[str, str], name: str) -> str | None:
    value = env.get(name)
    return value if value not in (None, "") else None


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
