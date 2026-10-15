"""Runtime configuration for the account and entitlement service (FEAT-013).

Values are read from the environment declared in `.env.example`; secrets are
never read from a repository file (NFR-024). Every value has a documented
default, so the service starts without an environment.

The allowance figures are the tiers in monetization.md "Pricing Tiers": Free
grants 20 lookups a month, Pro 50, and the 7-day trial carries the Pro allowance
for its length. A one-time top-up adds its lookups to the current period. The
figures are tunable here rather than hard-coded in the service, so a pricing
change is a configuration change and not a code change.

The paid-tier kill switch is read here too: it is a runtime release flag rather
than a pricing figure, so the environment's value is the source of truth.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass

# The audience asserted on internal service-to-service calls, and the header the
# services pass a correlation id along on.
DEFAULT_INTERNAL_AUDIENCE = "scenova-internal"
DEFAULT_CORRELATION_ID_HEADER = "x-correlation-id"

# monetization.md "Pricing Tiers": Free grants 20 lookups per month; Pro 50. The
# 7-day Pro trial carries the Pro allowance while it runs.
DEFAULT_FREE_LOOKUPS = 20
DEFAULT_PRO_LOOKUPS = 50
# monetization.md "Lookup Top-Up": one pack adds 20 lookups to the current month.
DEFAULT_TOPUP_LOOKUPS = 20
# monetization.md "Trial Period": a 7-day Pro trial at sign-up, no card.
DEFAULT_TRIAL_DAYS = 7

# nfr.md "Data lifecycle": a deleted account and its entitlement are hard-deleted
# within 30 days of the deletion request. The window is a policy the docs fix, not
# a per-environment setting, so it is a constant here rather than an environment
# variable.
RETENTION_DAYS = 30

# The `enable_paid_tier` release flag (release.md "Rollout Phases & Feature
# Flags"): when off, every reader is served and metered on the Free tier and the
# Paywall is hidden, so an exhausted allowance shows the word and phrase with no
# plan to buy. It defaults on here so a missing variable never silently reverts a
# reader who has paid; every environment supplies its rollout value through
# `FLAG_ENABLE_PAID_TIER`.
DEFAULT_ENABLE_PAID_TIER = True


@dataclass(frozen=True)
class Settings:
    """Account and entitlement settings, resolved from the environment."""

    auth_mode: str = "dev"
    firebase_project_id: str | None = None
    internal_audience: str = DEFAULT_INTERNAL_AUDIENCE
    correlation_id_header: str = DEFAULT_CORRELATION_ID_HEADER
    # The payment processor's webhook secret (C-019). It arrives from the secret
    # store and is never logged; empty means the webhook path is not configured
    # and only the internal service audience is accepted.
    webhook_auth: str | None = None
    require_internal_auth: bool = True
    free_lookups: int = DEFAULT_FREE_LOOKUPS
    pro_lookups: int = DEFAULT_PRO_LOOKUPS
    topup_lookups: int = DEFAULT_TOPUP_LOOKUPS
    trial_days: int = DEFAULT_TRIAL_DAYS
    retention_days: int = RETENTION_DAYS
    # The paid-tier kill switch; when off, every reader is served as Free.
    enable_paid_tier: bool = DEFAULT_ENABLE_PAID_TIER

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> Settings:
        source = os.environ if env is None else env
        environment = _env_str(source, "ENVIRONMENT", "dev")
        default_auth_mode = "firebase" if environment == "prod" else "dev"
        return cls(
            auth_mode=_env_str(source, "AUTH_MODE", default_auth_mode),
            firebase_project_id=_env_opt(source, "FIREBASE_PROJECT_ID"),
            internal_audience=_env_str(source, "INTERNAL_AUDIENCE", DEFAULT_INTERNAL_AUDIENCE),
            correlation_id_header=_env_str(
                source, "CORRELATION_ID_HEADER", DEFAULT_CORRELATION_ID_HEADER
            ),
            webhook_auth=_env_opt(source, "REVENUECAT_WEBHOOK_AUTH"),
            require_internal_auth=_env_bool(source, "ENTITLEMENT_REQUIRE_INTERNAL_AUTH", True),
            free_lookups=_env_int(source, "ENTITLEMENT_FREE_LOOKUPS", DEFAULT_FREE_LOOKUPS),
            pro_lookups=_env_int(source, "ENTITLEMENT_PRO_LOOKUPS", DEFAULT_PRO_LOOKUPS),
            topup_lookups=_env_int(source, "ENTITLEMENT_TOPUP_LOOKUPS", DEFAULT_TOPUP_LOOKUPS),
            trial_days=_env_int(source, "ENTITLEMENT_TRIAL_DAYS", DEFAULT_TRIAL_DAYS),
            enable_paid_tier=_env_bool(source, "FLAG_ENABLE_PAID_TIER", DEFAULT_ENABLE_PAID_TIER),
        )


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


def _env_bool(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value in (None, ""):
        return default
    return value.strip().lower() not in {"0", "false", "no", "off"}
