"""Runtime configuration for the notification service.

Values are read from the environment declared in `.env.example`; secrets are
never read from a repository file (NFR-024). Every value has a documented
default, so the service starts without an environment.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls. The generation
# pipeline sends it when it reports a finished clip (architecture "Notification
# Service": `Gen --> Notify`).
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"
DEFAULT_LOOKUP_PORT = "8081"
# The intake throttle the contract puts at the gateway (C-008, 429). The service
# applies the same fixed window as its own defence when it is addressed
# directly, so a flood is refused either way.
DEFAULT_RATE_LIMIT_PER_MINUTE = 120
DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 60
# Registration asks the lookup service about the lookup it is for (C-008, the
# "unknown lookup" refusal). The confirmation is not on the reader's fast path,
# so the wait stays short.
DEFAULT_LOOKUP_TIMEOUT_SECONDS = 3.0
# A push is a short outbound call to the push provider; when it cannot be made
# the notice is queued rather than lost, so the wait stays short too.
DEFAULT_PUSH_TIMEOUT_SECONDS = 5.0
# A bound on queued notices, so a long push outage cannot grow the queue without
# limit. This is backpressure, not loss.
DEFAULT_PENDING_NOTICE_LIMIT = 1000
# How often a queued notice is retried while the service runs. A provider outage
# delays a notice; this is what turns the queue back into a delivery rather than
# a leak (architecture "Notification Service"). Zero disables the loop.
DEFAULT_PUSH_DRAIN_INTERVAL_SECONDS = 30.0
# The configured provider. An empty value selects the logging seam, which is the
# local default until the provider is wired; `firebase` selects Firebase Cloud
# Messaging (the platform's configured provider).
DEFAULT_PUSH_PROVIDER = ""


@dataclass(frozen=True)
class Settings:
    """Notification settings, resolved from the environment."""

    auth_mode: str = "dev"
    firebase_project_id: str | None = None
    database_url: str | None = None
    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    require_internal_auth: bool = True
    lookup_base_url: str = f"http://127.0.0.1:{DEFAULT_LOOKUP_PORT}"
    lookup_timeout_seconds: float = DEFAULT_LOOKUP_TIMEOUT_SECONDS
    # The push provider's base URL for the generic HTTP seam. Empty (with the
    # provider left unset) selects the logging seam rather than an outbound call.
    # The platform's configured provider is Firebase Cloud Messaging, selected by
    # `push_provider` below.
    push_base_url: str = ""
    push_timeout_seconds: float = DEFAULT_PUSH_TIMEOUT_SECONDS
    # The configured push provider. `firebase` sends through Firebase Cloud
    # Messaging (HTTP v1); anything else falls back to the generic seam or the
    # logging seam.
    push_provider: str = DEFAULT_PUSH_PROVIDER
    # The Firebase Cloud Messaging send endpoint. A product-wide constant the
    # platform declares; sends are authorized from Application Default
    # Credentials, so no credential is stored here (NFR-024).
    push_fcm_base_url: str = ""
    push_drain_interval_seconds: float = DEFAULT_PUSH_DRAIN_INTERVAL_SECONDS
    rate_limit_per_minute: int = DEFAULT_RATE_LIMIT_PER_MINUTE
    rate_limit_window_seconds: int = DEFAULT_RATE_LIMIT_WINDOW_SECONDS
    pending_notice_limit: int = DEFAULT_PENDING_NOTICE_LIMIT

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
        return cls(
            auth_mode=_env_str(source, "AUTH_MODE", default_auth_mode),
            firebase_project_id=_env_opt(source, "FIREBASE_PROJECT_ID"),
            database_url=_env_opt(source, "DATABASE_URL"),
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            require_internal_auth=_env_bool(source, "NOTIFICATION_REQUIRE_INTERNAL_AUTH", True),
            lookup_base_url=lookup_base_url,
            lookup_timeout_seconds=_env_float(
                source, "NOTIFICATION_LOOKUP_TIMEOUT_SECONDS", DEFAULT_LOOKUP_TIMEOUT_SECONDS
            ),
            push_base_url=_env_str(source, "PUSH_BASE_URL", ""),
            push_timeout_seconds=_env_float(
                source, "NOTIFICATION_PUSH_TIMEOUT_SECONDS", DEFAULT_PUSH_TIMEOUT_SECONDS
            ),
            push_provider=_env_str(source, "PUSH_PROVIDER", DEFAULT_PUSH_PROVIDER).strip().lower(),
            push_fcm_base_url=_env_str(source, "PUSH_FCM_BASE_URL", ""),
            push_drain_interval_seconds=_env_float(
                source,
                "NOTIFICATION_PUSH_DRAIN_INTERVAL_SECONDS",
                DEFAULT_PUSH_DRAIN_INTERVAL_SECONDS,
            ),
            rate_limit_per_minute=_env_int(
                source, "NOTIFICATION_RATE_LIMIT_PER_MINUTE", DEFAULT_RATE_LIMIT_PER_MINUTE
            ),
            rate_limit_window_seconds=_env_int(
                source, "NOTIFICATION_RATE_LIMIT_WINDOW_SECONDS", DEFAULT_RATE_LIMIT_WINDOW_SECONDS
            ),
            pending_notice_limit=_env_int(
                source, "NOTIFICATION_PENDING_NOTICE_LIMIT", DEFAULT_PENDING_NOTICE_LIMIT
            ),
        )


def _env_str(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name)
    return value if value not in (None, "") else default


def _env_opt(env: Mapping[str, str], name: str) -> str | None:
    value = env.get(name)
    return value if value not in (None, "") else None


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
