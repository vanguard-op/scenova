"""Runtime configuration for the API gateway.

Values are read from the environment declared in `.env.example`; secrets are
never read from a repository file (NFR-024).
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"
DEFAULT_LOOKUP_PORT = "8081"
DEFAULT_ANALYTICS_PORT = "8086"
DEFAULT_NOTIFICATION_PORT = "8087"
DEFAULT_RATE_LIMIT_PER_MINUTE = 120
DEFAULT_EVENTS_RATE_LIMIT_PER_MINUTE = 120
DEFAULT_REGISTRATIONS_RATE_LIMIT_PER_MINUTE = 120
DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 60
DEFAULT_UPSTREAM_TIMEOUT_SECONDS = 10.0


@dataclass(frozen=True)
class Settings:
    """API gateway settings, resolved from the environment."""

    lookup_base_url: str = f"http://127.0.0.1:{DEFAULT_LOOKUP_PORT}"
    analytics_base_url: str = f"http://127.0.0.1:{DEFAULT_ANALYTICS_PORT}"
    notification_base_url: str = f"http://127.0.0.1:{DEFAULT_NOTIFICATION_PORT}"
    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    auth_mode: str = "dev"
    firebase_project_id: str | None = None
    rate_limit_per_minute: int = DEFAULT_RATE_LIMIT_PER_MINUTE
    events_rate_limit_per_minute: int = DEFAULT_EVENTS_RATE_LIMIT_PER_MINUTE
    registrations_rate_limit_per_minute: int = DEFAULT_REGISTRATIONS_RATE_LIMIT_PER_MINUTE
    rate_limit_window_seconds: int = DEFAULT_RATE_LIMIT_WINDOW_SECONDS
    upstream_timeout_seconds: float = DEFAULT_UPSTREAM_TIMEOUT_SECONDS
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER

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
        analytics_base_url = _env_str(
            source,
            "ANALYTICS_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'ANALYTICS_PORT', DEFAULT_ANALYTICS_PORT)}",
        )
        notification_base_url = _env_str(
            source,
            "NOTIFICATION_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'NOTIFICATION_PORT', DEFAULT_NOTIFICATION_PORT)}",
        )
        return cls(
            lookup_base_url=lookup_base_url,
            analytics_base_url=analytics_base_url,
            notification_base_url=notification_base_url,
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            auth_mode=_env_str(source, "AUTH_MODE", default_auth_mode),
            firebase_project_id=_env_opt(source, "FIREBASE_PROJECT_ID"),
            rate_limit_per_minute=_env_int(
                source, "RATE_LIMIT_LOOKUPS_PER_MINUTE", DEFAULT_RATE_LIMIT_PER_MINUTE
            ),
            events_rate_limit_per_minute=_env_int(
                source, "RATE_LIMIT_EVENTS_PER_MINUTE", DEFAULT_EVENTS_RATE_LIMIT_PER_MINUTE
            ),
            registrations_rate_limit_per_minute=_env_int(
                source,
                "RATE_LIMIT_REGISTRATIONS_PER_MINUTE",
                DEFAULT_REGISTRATIONS_RATE_LIMIT_PER_MINUTE,
            ),
            rate_limit_window_seconds=_env_int(
                source, "RATE_LIMIT_WINDOW_SECONDS", DEFAULT_RATE_LIMIT_WINDOW_SECONDS
            ),
            upstream_timeout_seconds=_env_float(
                source, "GATEWAY_UPSTREAM_TIMEOUT_SECONDS", DEFAULT_UPSTREAM_TIMEOUT_SECONDS
            ),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
        )


def _env_str(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name)
    return value if value not in (None, "") else default


def _env_opt(env: Mapping[str, str], name: str) -> str | None:
    value = env.get(name)
    return value if value not in (None, "") else None


def _env_int(env: Mapping[str, str], name: str, default: int) -> int:
    raw = _env_opt(env, name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_float(env: Mapping[str, str], name: str, default: float) -> float:
    raw = _env_opt(env, name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default
