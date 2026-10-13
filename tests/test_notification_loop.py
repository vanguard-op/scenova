"""Integration and acceptance tests for the clip-ready notification path.

Verifies FEAT-008's notify offer end to end against the frozen contract C-008
(`POST /v1/push-registrations`): a reader waiting on a clip registers a device
against the lookup, and when that lookup's generation finishes the notification
service pushes a clip-ready notice to the registered token. The whole path is
exercised across the gateway, lookup, pipeline, notification service, and a
push-provider double, with the external model provider (C-004, C-005) served by
a test double so a clip can actually be produced.

The notice carries the lookup and the clip only; the reader's selection never
travels to the push provider (nfr.md "Privacy"; FEAT-008).
"""

from __future__ import annotations

import time
from typing import Any
from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]


def _auth(subject: str = "reader-1") -> dict[str, str]:
    return {"Authorization": f"Bearer dev:{subject}"}


def _create(
    gateway: httpx2.Client,
    selection: str,
    *,
    client_id: str | None = None,
    subject: str = "reader-1",
    consent: bool = True,
) -> httpx2.Response:
    return gateway.post(
        "/v1/lookups",
        headers=_auth(subject),
        json={
            "selection": selection,
            "clientLookupId": client_id or f"id-{uuid4().hex}",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": consent,
        },
    )


def _register(
    gateway: httpx2.Client,
    *,
    lookup_id: str,
    token: str = "fcm-token-1",
    platform: str = "android",
    subject: str = "reader-1",
) -> httpx2.Response:
    return gateway.post(
        "/v1/push-registrations",
        headers=_auth(subject),
        json={"token": token, "platform": platform, "lookupId": lookup_id},
    )


def _notices(push: httpx2.Client) -> list[dict[str, Any]]:
    body: dict[str, Any] = push.get("/test/notices").json()
    notices = body.get("notices", [])
    return [notice for notice in notices if isinstance(notice, dict)]


def _wait_for_notice(push: httpx2.Client, lookup_id: str, *, attempts: int = 60) -> dict[str, Any]:
    for _ in range(attempts):
        for notice in _notices(push):
            if notice.get("notification", {}).get("data", {}).get("lookupId") == lookup_id:
                return notice
        time.sleep(0.25)
    pytest.fail(f"no clip-ready notice reached the push provider for lookup {lookup_id}")


# --- FEAT-008: the reader is offered a notice and gets it when the clip is ready


def test_a_reader_waiting_on_a_clip_is_notified_when_it_is_ready(
    notify_gateway: httpx2.Client,
    notify_push: httpx2.Client,
    notify_model_stub: httpx2.Client,
) -> None:
    # FEAT-008: generation passes the ten-second wait, the reader is offered to be
    # told when it is ready, and the notice arrives once the clip finishes.
    notify_model_stub.post("/test/reset")
    notify_push.post("/test/reset")
    # Hold the clip so the lookup is still generating when the reader registers.
    notify_model_stub.post("/test/config", json={"clipDelaySeconds": 1.0})

    created = _create(notify_gateway, "waiting", client_id="notify-wait")
    assert created.status_code == 200, created.text
    lookup_id = created.json()["lookupId"]
    assert created.json()["status"] == "generating"

    registered = _register(
        notify_gateway, lookup_id=lookup_id, token="fcm-token-abc", platform="android"
    )
    assert registered.status_code == 202, registered.text
    assert registered.json() == {"registered": True}

    notice = _wait_for_notice(notify_push, lookup_id)

    assert notice["token"] == "fcm-token-abc"
    assert notice["platform"] == "android"
    data = notice["notification"]["data"]
    assert data["resolution"] == "360p"
    assert 0 < data["durationSeconds"] <= 4
    assert data["clipUrl"].startswith("http")


def test_a_clip_ready_notice_carries_no_selection(
    notify_gateway: httpx2.Client,
    notify_push: httpx2.Client,
    notify_model_stub: httpx2.Client,
) -> None:
    # FEAT-008 / nfr.md "Privacy": nothing about the reader's selection reaches
    # the push provider; the notice names the lookup and the clip only.
    notify_model_stub.post("/test/reset")
    notify_push.post("/test/reset")
    notify_model_stub.post("/test/config", json={"clipDelaySeconds": 1.0})

    selection = "a secret phrase"
    created = _create(notify_gateway, selection, client_id="notify-private")
    lookup_id = created.json()["lookupId"]
    _register(notify_gateway, lookup_id=lookup_id)

    notice = _wait_for_notice(notify_push, lookup_id)

    serialised = str(notice)
    assert selection not in serialised
    assert "secret" not in serialised
    assert notice["notification"]["title"] == "Your clip is ready"


def test_a_registration_is_bound_to_the_reader_who_owns_the_lookup(
    notify_gateway: httpx2.Client,
    notify_model_stub: httpx2.Client,
) -> None:
    # C-008: the lookup must belong to the caller; another reader gets no token
    # stored against it.
    notify_model_stub.post("/test/reset")
    notify_model_stub.post("/test/config", json={"clipDelaySeconds": 1.0})

    created = _create(notify_gateway, "borrowed", client_id="notify-owner", subject="reader-1")
    lookup_id = created.json()["lookupId"]

    response = _register(notify_gateway, lookup_id=lookup_id, subject="reader-2")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "unknown_lookup"


# --- C-008: the registration intake's refusals --------------------------------


def test_a_registration_without_a_token_is_unauthorized(notify_gateway: httpx2.Client) -> None:
    response = notify_gateway.post(
        "/v1/push-registrations",
        json={"token": "fcm-1", "platform": "android", "lookupId": "lk_1"},
    )

    assert response.status_code == 401, response.text
    assert response.json()["code"] == "unauthorized"


def test_a_registration_for_an_unknown_lookup_is_refused(notify_gateway: httpx2.Client) -> None:
    response = _register(notify_gateway, lookup_id="lk_does_not_exist")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "unknown_lookup"


def test_a_registration_for_a_non_generating_lookup_is_declined(
    notify_gateway: httpx2.Client,
) -> None:
    # C-008: a lookup that has already resolved needs no notice, so the intake
    # reports it rather than holding a token for an event that will not come.
    denied = _create(notify_gateway, "coming", client_id="notify-denied", consent=False)
    lookup_id = denied.json()["lookupId"]
    assert denied.json()["status"] == "denied"

    response = _register(notify_gateway, lookup_id=lookup_id)

    assert response.status_code == 202, response.text
    assert response.json() == {"registered": False}


def test_an_unreadable_token_is_refused(
    notify_gateway: httpx2.Client,
    notify_model_stub: httpx2.Client,
) -> None:
    notify_model_stub.post("/test/config", json={"clipDelaySeconds": 1.0})
    created = _create(notify_gateway, "blank", client_id="notify-blank")

    response = _register(notify_gateway, lookup_id=created.json()["lookupId"], token="   ")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "unreadable_token"


def test_an_unknown_platform_is_a_bad_request(notify_gateway: httpx2.Client) -> None:
    response = _register(notify_gateway, lookup_id="lk_1", platform="web")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "invalid_request"
