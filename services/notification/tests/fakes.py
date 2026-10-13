"""Shared test doubles and builders for the notification tests."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

from fastapi.testclient import TestClient

from notification.app.api import create_app
from notification.app.config import Settings
from notification.app.lookups import LookupStatus, LookupUnavailableError
from notification.app.models import Platform
from notification.app.push import ClipReadyNotice, PushUnavailableError
from notification.app.ratelimit import InMemoryFixedWindowRateLimiter
from notification.app.service import NotificationService
from notification.app.store import InMemoryRegistrationStore

AUTH = {"Authorization": "Bearer dev:reader-1"}
INTERNAL = {"x-internal-audience": "scenova-internal"}
SUBJECT = "reader-1"


class FakeLookupDirectory:
    """A directory with scripted lookup states for one subject.

    `statuses` maps `(lookup_id, subject)` to a status; a missing key is an
    unknown lookup. `unavailable` makes every read raise, as an outage would.
    """

    def __init__(
        self,
        statuses: dict[tuple[str, str], LookupStatus] | None = None,
        *,
        unavailable: bool = False,
    ) -> None:
        self.statuses = dict(statuses or {})
        self.unavailable = unavailable
        self.calls: list[tuple[str, str]] = []

    async def status(self, lookup_id: str, subject: str) -> LookupStatus | None:
        self.calls.append((lookup_id, subject))
        if self.unavailable:
            raise LookupUnavailableError("The lookup service is unreachable.")
        return self.statuses.get((lookup_id, subject))

    async def aclose(self) -> None:
        return None


class FakePushSender:
    """A sender that records every notice, and can be scripted to fail.

    `sent_event` is set on every successful send, so a test can wait for a
    delivery rather than poll for one.
    """

    def __init__(self, *, unavailable: bool = False) -> None:
        self.sent: list[tuple[str, Platform, ClipReadyNotice]] = []
        self.unavailable = unavailable
        self.sent_event = asyncio.Event()

    async def send(self, *, token: str, platform: Platform, notice: ClipReadyNotice) -> None:
        if self.unavailable:
            raise PushUnavailableError("The push provider is unreachable.")
        self.sent.append((token, platform, notice))
        self.sent_event.set()

    async def aclose(self) -> None:
        return None


class FakeTokenProvider:
    """A token provider that returns a fixed access token without any network."""

    def __init__(self, value: str = "ya29.test-token") -> None:
        self.token_value = value
        self.calls = 0

    def token(self) -> str:
        self.calls += 1
        return self.token_value


@dataclass
class Rig:
    """The service under test with the doubles it was built from."""

    service: NotificationService
    store: InMemoryRegistrationStore
    lookups: FakeLookupDirectory
    sender: FakePushSender
    statuses: dict[tuple[str, str], LookupStatus] = field(default_factory=dict)


def rig(
    statuses: dict[tuple[str, str], LookupStatus] | None = None,
    *,
    lookup_unavailable: bool = False,
    push_unavailable: bool = False,
    pending_limit: int = 1000,
) -> Rig:
    """Wire the service with a fake directory and push sender."""

    resolved = dict(statuses or {})
    lookups = FakeLookupDirectory(resolved, unavailable=lookup_unavailable)
    sender = FakePushSender(unavailable=push_unavailable)
    store = InMemoryRegistrationStore()
    service = NotificationService(
        store=store,
        lookups=lookups,
        sender=sender,
        pending_limit=pending_limit,
    )
    return Rig(
        service=service,
        store=store,
        lookups=lookups,
        sender=sender,
        statuses=resolved,
    )


def generating(lookup_id: str = "lk_1") -> dict[tuple[str, str], LookupStatus]:
    """The status map for a lookup the subject owns and is still waiting on."""

    return {(lookup_id, SUBJECT): LookupStatus.GENERATING}


def make_client(
    *,
    service: NotificationService | None = None,
    settings: Settings | None = None,
    rate_limit: int = 120,
    run_drain_loop: bool = False,
) -> TestClient:
    """A client for the service with the dev verifier and a frozen clock limiter.

    The queued-notice retry is off by default so a test drives the queue
    deterministically; the drain has its own test.
    """

    resolved_settings = settings or Settings()
    resolved_service = service or build_fake_service(resolved_settings)
    return TestClient(
        create_app(
            settings=resolved_settings,
            service=resolved_service,
            limiter=InMemoryFixedWindowRateLimiter(
                limit=rate_limit, window_seconds=60, clock=lambda: 0.0
            ),
            run_drain_loop=run_drain_loop,
        )
    )


def build_fake_service(settings: Settings) -> NotificationService:
    """A service with no outbound clients, for tests that never reach them."""

    return NotificationService(
        store=InMemoryRegistrationStore(),
        lookups=FakeLookupDirectory(),
        sender=FakePushSender(),
        pending_limit=settings.pending_notice_limit,
    )


def register_body(**overrides: object) -> dict[str, object]:
    """A valid `push-registrations` body, with any field overridden."""

    body: dict[str, object] = {
        "token": "fcm-token-1",
        "platform": "android",
        "lookupId": "lk_1",
    }
    body.update(overrides)
    return body


def clip_ready_body(**overrides: object) -> dict[str, object]:
    """A valid clip-ready ingest body, with any field overridden."""

    body: dict[str, object] = {
        "lookupId": "lk_1",
        "jobId": "job_1",
        "clip": clip_descriptor(),
    }
    body.update(overrides)
    return body


def clip_descriptor(**overrides: object) -> dict[str, object]:
    """A finished-clip descriptor, mirroring the C-005 clip shape."""

    body: dict[str, object] = {
        "clipId": "clip_1",
        "storageKey": "clips/clip_1.mp4",
        "url": "https://cdn.example/clip_1.mp4",
        "durationSeconds": 3.0,
        "resolution": "360p",
        "hasAudio": False,
        "synthIdWatermark": True,
    }
    body.update(overrides)
    return body
