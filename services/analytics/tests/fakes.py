"""Shared test doubles and builders for the analytics tests."""

from __future__ import annotations

from fastapi.testclient import TestClient

from analytics.app.api import create_app
from analytics.app.config import Settings
from analytics.app.models import IngestRequest
from analytics.app.ratelimit import InMemoryFixedWindowRateLimiter
from analytics.app.service import EventService, build_default_service

AUTH = {"Authorization": "Bearer dev:reader-1"}


def make_client(
    *,
    service: EventService | None = None,
    settings: Settings | None = None,
    rate_limit: int = 120,
) -> TestClient:
    """A client for the intake with the dev verifier and a frozen clock limiter."""

    resolved_settings = settings or Settings()
    resolved_service = service or build_default_service(resolved_settings)
    return TestClient(
        create_app(
            settings=resolved_settings,
            service=resolved_service,
            limiter=InMemoryFixedWindowRateLimiter(
                limit=rate_limit, window_seconds=60, clock=lambda: 0.0
            ),
        )
    )


def event(**overrides: object) -> dict[str, object]:
    """A valid `lookup_started` event, with any field overridden."""

    body: dict[str, object] = {
        "eventId": "evt-1",
        "name": "lookup_started",
        "occurredAt": "2026-10-13T12:00:00Z",
        "anonymousId": "anon-1",
        "sessionId": "sess-1",
        "platform": "android",
        "appVersion": "1.0.0+1",
        "locale": "en",
        "properties": {"kind": "word", "source": "typed"},
    }
    body.update(overrides)
    return body


def batch(*events: dict[str, object]) -> IngestRequest:
    """An `IngestRequest` built from event dictionaries."""

    return IngestRequest.model_validate({"events": list(events)})
