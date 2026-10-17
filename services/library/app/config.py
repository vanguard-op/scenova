"""Runtime configuration for the shared word-clip library.

Values are read from the environment declared in `.env.example`; nothing secret
is read here (NFR-024). The library is internal-only, so the settings are the
audience asserted between services, the correlation header they pass along, and
the primary database the entries live in.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls. The lookup and
# pipeline services send it when they read from and write to the library.
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"


@dataclass(frozen=True)
class Settings:
    """Shared library settings, resolved from the environment."""

    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    require_internal_auth: bool = True
    # The interactive schema (Swagger UI, ReDoc, OpenAPI) is a development aid,
    # never a published surface (nfr.md "Security"); `from_env` serves it only
    # for local development, and `DOCS_ENABLED` overrides that.
    docs_enabled: bool = False
    # The primary database the library entries live in (architecture.md "Primary
    # Database"). Empty resolves to the in-memory store, which the unit tests and
    # a bare local run use; every deployed environment supplies it.
    database_url: str | None = None

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        environment = _env_str(source, "ENVIRONMENT", "dev")
        return cls(
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            require_internal_auth=_env_bool(source, "LIBRARY_REQUIRE_INTERNAL_AUTH", True),
            docs_enabled=_env_bool(source, "DOCS_ENABLED", environment == "dev"),
            database_url=_env_optional(source, "DATABASE_URL"),
        )


def _env_str(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name)
    return value if value not in (None, "") else default


def _env_optional(env: Mapping[str, str], name: str) -> str | None:
    value = env.get(name)
    return value if value not in (None, "") else None


def _env_bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value in (None, ""):
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}
