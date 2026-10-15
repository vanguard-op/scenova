"""Shared test doubles and builders for the entitlement tests."""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any, cast

from fastapi.testclient import TestClient

from entitlement.app.api import create_app
from entitlement.app.auth import DevTokenVerifier
from entitlement.app.config import Settings
from entitlement.app.service import EntitlementService
from entitlement.app.store import InMemoryEntitlementStore

# The reader path: a signed-in reader, an anonymous device before sign-in, the
# internal service audience, and the payment processor's webhook secret.
READER = {"Authorization": "Bearer dev:reader-1"}
SUBJECT = "reader-1"
ANONYMOUS = {"Authorization": "Bearer dev-anon:device-9"}
INTERNAL = {"x-internal-audience": "scenova-internal"}
WEBHOOK = {"Authorization": "processor-secret"}

# A fixed moment, so a trial end or a period boundary is a value a test sets
# rather than a race against the wall clock.
START = datetime(2026, 10, 15, 12, 0, tzinfo=UTC)


class Clock:
    """A clock a test moves by hand."""

    def __init__(self, moment: datetime = START) -> None:
        self.moment = moment

    def __call__(self) -> datetime:
        return self.moment

    def advance(self, **delta: float) -> None:
        self.moment = self.moment + timedelta(**delta)


@dataclass
class Rig:
    """The service under test with the store and clock it was built from."""

    service: EntitlementService
    store: InMemoryEntitlementStore
    clock: Clock = field(default_factory=Clock)


def rig(
    *,
    free_lookups: int = 20,
    pro_lookups: int = 50,
    topup_lookups: int = 20,
    trial_days: int = 7,
    retention_days: int = 30,
    paid_tier_enabled: bool = True,
    clock: Clock | None = None,
    store: InMemoryEntitlementStore | None = None,
) -> Rig:
    """Wire the service with an in-memory store and a movable clock.

    A caller can pass an existing store and clock to build a second service over
    the same data, which is how a release-flag flip is exercised.
    """

    resolved_clock = clock or Clock()
    resolved_store = store if store is not None else InMemoryEntitlementStore()
    service = EntitlementService(
        store=resolved_store,
        free_lookups=free_lookups,
        pro_lookups=pro_lookups,
        topup_lookups=topup_lookups,
        trial_days=trial_days,
        retention_days=retention_days,
        paid_tier_enabled=paid_tier_enabled,
        clock=resolved_clock,
    )
    return Rig(service=service, store=resolved_store, clock=resolved_clock)


def settings(**overrides: object) -> Settings:
    """The test settings: dev auth, internal auth on, a webhook secret set."""

    values: dict[str, object] = {
        "auth_mode": "dev",
        "require_internal_auth": True,
        "webhook_auth": "processor-secret",
    }
    values.update(overrides)
    return Settings(**values)  # type: ignore[arg-type]


def make_client(rigged: Rig, *, config: Settings | None = None) -> TestClient:
    """A client for the service with the dev verifier."""

    return TestClient(
        create_app(
            settings=config or settings(),
            service=rigged.service,
            verifier=DevTokenVerifier(),
        )
    )


def provision(client: TestClient, headers: dict[str, str] = READER) -> dict[str, Any]:
    """Read the entitlement once, which creates the reader's account."""

    response = client.get("/v1/entitlement", headers=headers)
    assert response.status_code == 200, response.text
    return cast(dict[str, Any], response.json())


def sync_body(**overrides: object) -> dict[str, object]:
    """A valid C-019 body, with any field overridden."""

    body: dict[str, object] = {
        "accountId": SUBJECT,
        "event": "purchase",
        "store": "app_store",
        "productId": "scenova.pro.monthly",
        "productKind": "subscription",
        "amountMinor": 699,
        "currency": "USD",
        "occurredAt": "2026-10-15T12:00:00+00:00",
    }
    body.update(overrides)
    return body
