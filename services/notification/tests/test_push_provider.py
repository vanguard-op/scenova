"""Delivery through the configured push provider (FEAT-008, C-008).

The platform configures Firebase Cloud Messaging as the push provider
(architecture.md "External Integrations"). A send goes to the target project's
`messages:send` endpoint, authorized by a short-lived OAuth 2.0 token from
Application Default Credentials, and the notice carries the lookup and the clip
only — never the reader's selection.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

import httpx2
import pytest

from notification.app.config import Settings
from notification.app.models import Platform
from notification.app.push import (
    NOTICE_BODY,
    NOTICE_TITLE,
    ClipReadyNotice,
    FcmPushSender,
    HttpPushSender,
    LoggingPushSender,
    PushUnavailableError,
)
from notification.app.service import build_push_sender
from notification.tests.fakes import FakeTokenProvider


def _notice() -> ClipReadyNotice:
    return ClipReadyNotice(
        lookup_id="lk_1",
        job_id="job_1",
        clip_url="https://cdn.example/clip_1.mp4",
        duration_seconds=3.0,
        resolution="360p",
        has_audio=False,
    )


def _sender(
    handler: Callable[[httpx2.Request], httpx2.Response],
    *,
    project_id: str | None = "scenova-prod",
) -> tuple[FcmPushSender, FakeTokenProvider]:
    tokens = FakeTokenProvider()
    sender = FcmPushSender(
        base_url="https://fcm.googleapis.com",
        project_id=project_id,
        transport=httpx2.MockTransport(handler),
        token_provider=tokens,
    )
    return sender, tokens


@pytest.mark.asyncio
async def test_a_notice_is_sent_through_firebase_cloud_messaging() -> None:
    seen: dict[str, Any] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["path"] = request.url.path
        seen["authorization"] = request.headers.get("Authorization")
        seen["body"] = json.loads(request.content)
        return httpx2.Response(200, json={"name": "projects/scenova-prod/messages/1"})

    sender, tokens = _sender(handler)
    await sender.send(token="fcm-token-1", platform=Platform.ANDROID, notice=_notice())

    assert seen["path"] == "/v1/projects/scenova-prod/messages:send"
    assert seen["authorization"] == "Bearer ya29.test-token"
    assert tokens.calls == 1
    assert seen["body"] == {
        "message": {
            "token": "fcm-token-1",
            "notification": {"title": NOTICE_TITLE, "body": NOTICE_BODY},
            "data": {
                "lookupId": "lk_1",
                "clipUrl": "https://cdn.example/clip_1.mp4",
                "durationSeconds": "3.0",
                "resolution": "360p",
                "hasAudio": "false",
            },
        }
    }
    await sender.aclose()


@pytest.mark.asyncio
async def test_the_push_message_never_carries_the_reader_selection() -> None:
    seen: dict[str, Any] = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen["body"] = request.content.decode()
        return httpx2.Response(200, json={"name": "projects/scenova-prod/messages/1"})

    sender, _ = _sender(handler)
    await sender.send(token="fcm-token-1", platform=Platform.IOS, notice=_notice())

    body = str(seen["body"]).casefold()
    assert "selection" not in body
    assert "phrase" not in body
    assert "lemma" not in body
    await sender.aclose()


@pytest.mark.asyncio
@pytest.mark.parametrize("status", [429, 500, 503, 401, 403])
async def test_a_provider_that_cannot_take_the_notice_is_queued(status: int) -> None:
    # A provider that is down, throttles, or refuses the credential delays the
    # notice (it is queued) rather than losing it.
    sender, _ = _sender(lambda _request: httpx2.Response(status, json={"error": "denied"}))

    with pytest.raises(PushUnavailableError):
        await sender.send(token="fcm-token-1", platform=Platform.ANDROID, notice=_notice())
    await sender.aclose()


@pytest.mark.asyncio
async def test_an_unregistered_token_is_dropped_rather_than_queued() -> None:
    # Retrying will never register a rejected token, so a 404 is dropped, not
    # queued forever.
    sender, _ = _sender(lambda _request: httpx2.Response(404, json={"error": "UNREGISTERED"}))

    await sender.send(token="fcm-token-1", platform=Platform.ANDROID, notice=_notice())
    await sender.aclose()


@pytest.mark.asyncio
async def test_a_missing_firebase_project_is_reported_rather_than_sent() -> None:
    sender, tokens = _sender(lambda _request: httpx2.Response(200), project_id=None)

    with pytest.raises(PushUnavailableError):
        await sender.send(token="fcm-token-1", platform=Platform.ANDROID, notice=_notice())
    assert tokens.calls == 0
    await sender.aclose()


@pytest.mark.asyncio
async def test_the_configured_provider_selects_the_sender() -> None:
    cases: list[tuple[Settings, type[object]]] = [
        (
            Settings.from_env(
                {
                    "PUSH_PROVIDER": "firebase",
                    "PUSH_FCM_BASE_URL": "https://fcm.googleapis.com",
                    "FIREBASE_PROJECT_ID": "scenova-prod",
                }
            ),
            FcmPushSender,
        ),
        # Firebase selected but no send endpoint declared: fall back rather than
        # build a sender that could never send.
        (Settings.from_env({"PUSH_PROVIDER": "firebase"}), LoggingPushSender),
        (Settings.from_env({"PUSH_BASE_URL": "http://127.0.0.1:9/push"}), HttpPushSender),
        (Settings.from_env({}), LoggingPushSender),
    ]

    for settings, expected in cases:
        sender = build_push_sender(settings)
        assert isinstance(sender, expected)
        await sender.aclose()
