"""Acceptance tests for the on-demand phrase clip (FEAT-007).

Verifies FEAT-007 end to end against the frozen contracts and the feature's
acceptance criteria and edge cases.

A phrase clip has one delivery path and it is the clip-ready notice: the lookup
that started the generation shows the phrase with no clip, and no clip is served
from the lookup read path or held for later serving (FEAT-007; C-001 revision 2,
C-002 revision 2, C-008 revision 2). The clip is generated for the requesting
device only and is never written to the shared library.

The server-side half is verified here: the read path never carries the clip, the
clip is produced, no central entry is written, and the clip-ready notice reaches
the registered device carrying the clip. The device-side half — the clip playing
from the notice and being saved only to device history — is covered by the
client's own tests (`apps/mobile/test/clip_notice_flow_test.dart`), since the
client is not driven from this Python harness.
"""

from __future__ import annotations

import time
from typing import Any
from uuid import uuid4

import httpx2
import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

INTERNAL = {"x-internal-audience": "scenova-internal"}
_PHRASE = "a walk in the park"


def _auth(subject: str = "reader-1") -> dict[str, str]:
    return {"Authorization": f"Bearer dev:{subject}"}


def _create(
    gateway: httpx2.Client,
    selection: str,
    *,
    subject: str = "reader-1",
) -> httpx2.Response:
    return gateway.post(
        "/v1/lookups",
        headers=_auth(subject),
        json={
            "selection": selection,
            "clientLookupId": f"phrase-{uuid4().hex}",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": True,
        },
    )


def _register(
    gateway: httpx2.Client,
    *,
    lookup_id: str,
    token: str = "phrase-token-1",
    subject: str = "reader-1",
) -> httpx2.Response:
    return gateway.post(
        "/v1/push-registrations",
        headers=_auth(subject),
        json={"token": token, "platform": "android", "lookupId": lookup_id},
    )


def _wait_for_clip_call(stub: httpx2.Client, *, attempts: int = 200) -> None:
    """Wait until the provider double has answered at least one clip call."""

    calls: dict[str, int] = {}
    for _ in range(attempts):
        calls = stub.get("/test/calls").json()
        if calls.get("clip", 0) >= 1:
            return
        time.sleep(0.05)
    pytest.fail(f"no phrase clip was generated: {calls}")


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


def _library_find(library: httpx2.Client, phrase: str) -> httpx2.Response:
    return library.get(
        "/internal/library/entries",
        headers=INTERNAL,
        params={"lemma": phrase, "senseLabel": "phrase", "partOfSpeech": "other"},
    )


def test_a_phrase_lookup_shows_the_phrase_with_no_clip(
    loop_gateway: httpx2.Client,
    loop_model_stub: httpx2.Client,
) -> None:
    # FEAT-007: "Given a short phrase is looked up, When the lookup responds while
    # the clip is being made, Then the phrase is shown with no clip and no clip is
    # returned by the lookup." The read path never serves a phrase clip — even
    # after generation finishes — because the clip arrives only by the notice
    # (C-001 revision 2, C-002 revision 2).
    loop_model_stub.post("/test/reset")

    created = _create(loop_gateway, _PHRASE)
    assert created.status_code == 200, created.text
    body = created.json()
    assert body["kind"] == "phrase"
    assert body["status"] == "generating"
    assert body["senses"] == []
    assert body["notice"] is None

    # Let the clip finish, then poll again: the lookup still carries no clip.
    _wait_for_clip_call(loop_model_stub)
    polled = loop_gateway.get(f"/v1/lookups/{body['lookupId']}", headers=_auth()).json()
    assert polled["kind"] == "phrase"
    assert polled["status"] != "served", (
        "a phrase lookup must never read as served: the clip is delivered by the "
        "clip-ready notice, not on the lookup response (C-001/C-002 revision 2)"
    )
    assert all(sense["clip"] is None for sense in polled["senses"])


def test_a_phrase_clip_is_generated_and_never_stored_centrally(
    loop_gateway: httpx2.Client,
    loop_library: httpx2.Client,
    loop_model_stub: httpx2.Client,
) -> None:
    # FEAT-007 / FEAT-006: "Given a short phrase is selected, When a clip is
    # generated, Then the clip is shown and saved only on the device." The clip is
    # produced for the requesting device and never written to the shared library.
    loop_model_stub.post("/test/reset")

    created = _create(loop_gateway, _PHRASE)
    assert created.status_code == 200, created.text
    assert created.json()["kind"] == "phrase"

    _wait_for_clip_call(loop_model_stub)

    found = _library_find(loop_library, _PHRASE)
    assert found.status_code == 200, found.text
    assert found.json() == {"entry": None}


def test_the_phrase_clip_reaches_the_device_by_the_clip_ready_notice(
    notify_gateway: httpx2.Client,
    notify_push: httpx2.Client,
    notify_model_stub: httpx2.Client,
) -> None:
    # FEAT-007: "Given the phrase clip is generated, When the clip-ready notice
    # reaches the device, Then the clip plays and is saved only on the device."
    # The notice is the phrase's only delivery path, so the device is registered
    # against the lookup and the notice carries the clip (C-008 revision 2).
    notify_model_stub.post("/test/reset")
    notify_push.post("/test/reset")
    # Hold the clip so the lookup is still generating when the device registers.
    notify_model_stub.post("/test/config", json={"clipDelaySeconds": 1.0})

    created = _create(notify_gateway, _PHRASE)
    assert created.status_code == 200, created.text
    created_body = created.json()
    assert created_body["kind"] == "phrase"
    assert created_body["status"] == "generating"

    registered = _register(notify_gateway, lookup_id=created_body["lookupId"])
    assert registered.status_code == 202, registered.text
    assert registered.json() == {"registered": True}

    notice = _wait_for_notice(notify_push, created_body["lookupId"])
    data = notice["notification"]["data"]
    assert data["lookupId"] == created_body["lookupId"]
    assert data["clipUrl"].startswith("http")
    assert data["resolution"] == "360p"
    assert 0 < data["durationSeconds"] <= 4
    # The notice carries the lookup and the clip only; the reader's selection
    # never travels to the push provider (nfr.md "Privacy").
    assert _PHRASE not in str(notice)
