"""Runtime configuration for the generation pipeline.

Every value has a documented default, so the service starts without an
environment; nothing secret is read here (NFR-024). The clip cap is a constant
rather than an environment variable: it is part of the pinned output contract
the quality bar was measured on, so it changes with the feature, not per
environment.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls (C-003, C-004,
# C-005). The lookup service sends it when it enqueues a generation job.
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_MODEL_PORT = "8090"
# Clip generation is a long-running job (NFR-003, NFR-004), so the internal
# client waits far longer than the lookup path does.
DEFAULT_MODEL_TIMEOUT_SECONDS = 120.0
# Clips are capped at four seconds so they resolve within a reader's glance.
CLIP_MAX_DURATION_SECONDS = 4.0
# The `enable_generation` release flag (release.md "Rollout Phases & Feature
# Flags"): the runtime kill switch that stops new generation while the shared
# library and device history keep serving. It defaults on here so a missing
# variable never silently disables the feature; every environment supplies its
# rollout value (off until the phase rolls out) through `FLAG_ENABLE_GENERATION`.
DEFAULT_ENABLE_GENERATION = True


@dataclass(frozen=True)
class Settings:
    """Generation pipeline settings, resolved from the environment."""

    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    require_internal_auth: bool = True
    model_base_url: str = f"http://127.0.0.1:{DEFAULT_MODEL_PORT}"
    model_timeout_seconds: float = DEFAULT_MODEL_TIMEOUT_SECONDS
    clip_max_duration_seconds: float = CLIP_MAX_DURATION_SECONDS
    # A generation-cost ceiling, in provider clip calls; 0 means no ceiling.
    generation_budget_units: float = 0.0
    # The generation kill switch; when off, a job stops before any provider call.
    enable_generation: bool = DEFAULT_ENABLE_GENERATION

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        model_base_url = _env_str(
            source,
            "MODEL_BASE_URL",
            f"http://127.0.0.1:{_env_str(source, 'MODEL_PORT', DEFAULT_MODEL_PORT)}",
        )
        return cls(
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            require_internal_auth=_env_bool(source, "PIPELINE_REQUIRE_INTERNAL_AUTH", True),
            model_base_url=model_base_url,
            model_timeout_seconds=_env_float(
                source, "PIPELINE_MODEL_TIMEOUT_SECONDS", DEFAULT_MODEL_TIMEOUT_SECONDS
            ),
            generation_budget_units=_env_float(source, "PIPELINE_GENERATION_BUDGET_UNITS", 0.0),
            enable_generation=_env_bool(
                source, "FLAG_ENABLE_GENERATION", DEFAULT_ENABLE_GENERATION
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
