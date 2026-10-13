"""Runtime configuration for the analytics event intake.

Every value has a documented default, so the service starts without an
environment; secrets are never read from a repository file (NFR-024). The
consent-gated set and the event store are the analytics variables in
`.env.example`; the retention window is a constant, because it is a policy the
docs fix (`nfr.md` "Data lifecycle"), not a per-environment setting.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

from .taxonomy import DEFAULT_GATED_EVENTS, EventName

DEFAULT_RATE_LIMIT_PER_MINUTE = 120
DEFAULT_RATE_LIMIT_WINDOW_SECONDS = 60
# Raw events are kept for fourteen months and then aggregated or deleted
# (`nfr.md` "Data lifecycle"; `analytics.md` "Analytics Data Governance").
RETENTION_MONTHS = 14
# No sampling at launch; if a rate below one is ever configured it is applied at
# that stated rate so counts are read correctly.
DEFAULT_SAMPLE_RATE = 1.0


@dataclass(frozen=True)
class Settings:
    """Analytics settings, resolved from the environment."""

    auth_mode: str = "dev"
    firebase_project_id: str | None = None
    # The sink identifier the events are written to; empty means in-memory.
    event_store: str = ""
    consent_gated_events: frozenset[EventName] = DEFAULT_GATED_EVENTS
    sample_rate: float = DEFAULT_SAMPLE_RATE
    rate_limit_per_minute: int = DEFAULT_RATE_LIMIT_PER_MINUTE
    rate_limit_window_seconds: int = DEFAULT_RATE_LIMIT_WINDOW_SECONDS
    retention_months: int = RETENTION_MONTHS

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        environment = _env_str(source, "ENVIRONMENT", "dev")
        default_auth_mode = "firebase" if environment == "prod" else "dev"
        return cls(
            auth_mode=_env_str(source, "AUTH_MODE", default_auth_mode),
            firebase_project_id=_env_opt(source, "FIREBASE_PROJECT_ID"),
            event_store=_env_str(source, "ANALYTICS_EVENT_STORE", ""),
            consent_gated_events=_gated_events(source.get("ANALYTICS_CONSENT_GATED_EVENTS")),
            sample_rate=_env_rate(source, "ANALYTICS_SAMPLE_RATE", DEFAULT_SAMPLE_RATE),
            rate_limit_per_minute=_env_int(
                source, "ANALYTICS_RATE_LIMIT_PER_MINUTE", DEFAULT_RATE_LIMIT_PER_MINUTE
            ),
            rate_limit_window_seconds=_env_int(
                source, "ANALYTICS_RATE_LIMIT_WINDOW_SECONDS", DEFAULT_RATE_LIMIT_WINDOW_SECONDS
            ),
        )


def _gated_events(raw: str | None) -> frozenset[EventName]:
    """Parse the comma-separated consent-gated event names.

    An unset or unrecognised value falls back to the taxonomy's reading-behaviour
    set, so a typo never widens what is stored without consent.
    """

    if raw is None or raw.strip() == "":
        return DEFAULT_GATED_EVENTS
    names: set[EventName] = set()
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        try:
            names.add(EventName(token))
        except ValueError:
            continue
    return frozenset(names) if names else DEFAULT_GATED_EVENTS


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


def _env_rate(env: Mapping[str, str], name: str, default: float) -> float:
    raw = _env_opt(env, name)
    if raw is None:
        return default
    try:
        return min(max(float(raw), 0.0), 1.0)
    except ValueError:
        return default
