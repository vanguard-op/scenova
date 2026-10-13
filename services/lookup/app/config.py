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


@dataclass(frozen=True)
class Settings:
    """Lookup service settings, resolved from the environment."""

    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    require_internal_auth: bool = True

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        return cls(
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            require_internal_auth=_env_bool(source, "LOOKUP_REQUIRE_INTERNAL_AUTH", True),
        )


def _env_str(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name)
    return value if value not in (None, "") else default


def _env_bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value in (None, ""):
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}
