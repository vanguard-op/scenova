"""Integration and acceptance tests for the trust-and-continuity loop.

Verifies FEAT-010 (clip feedback, C-012), FEAT-011 (report a clip, C-013), and
FEAT-015 (library review console, C-014 to C-016) end to end across the shipped
services: a reader looks a word up, is served a clip from the shared library,
rates or reports it through the gateway, the entry is queued for review and keeps
serving while a fresh clip is regenerated for the reporting reader, and a curator
works the queue and chooses which clip serves the entry.

The moderation change is the semantics these tests assert: a report does not
withdraw the clip other readers are using. It regenerates one clip for the entry,
held on the entry's queue item as the curator's candidate and delivered to the
reporting reader; the entry keeps serving the clip it already serves until the
curator chooses a clip or retires it. There is no `held` entry status and no
`hold`, `clear`, or `replace` action: the library moves between `active` and
`retired`, and a curator resolves an item with `choose` (naming the serving clip
or the candidate), `retire`, or `edit_phrase`.

The stack boots the feedback service beside the lookup, library, pipeline,
notification, and analytics services, with the model provider and the push
provider as local doubles, so a word lookup produces a clip to rate and report, a
report's regenerated clip reaches the reporting reader by the clip-ready notice
(C-008), and a curator's action has a generation to hand off. Each test uses its
own invented word, so the shared library, lookup store, and review queue carry no
state between tests.
"""

from __future__ import annotations

import time
from typing import Any
from uuid import uuid4

import httpx2
import pytest

from tests.conftest import INTERNAL_AUDIENCE

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

INTERNAL = {"x-internal-audience": INTERNAL_AUDIENCE}
# The dev operator verifier accepts `dev:curator:mfa:<subject>` for a curator with
# a second factor (D-011, FEAT-015's operator gate).
OPERATOR = {"Authorization": "Bearer dev:curator:mfa:curator-1"}
# An out-of-inventory word resolves under this key: sense label `meaning`, part of
# speech `other` (the lookup service's out-of-inventory sense).
_MEANING = {"senseLabel": "meaning", "partOfSpeech": "other"}


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


def _poll_until_settled(
    gateway: httpx2.Client,
    lookup_id: str,
    *,
    subject: str = "reader-1",
    attempts: int = 80,
    delay: float = 0.25,
) -> dict[str, Any]:
    body: dict[str, Any] = {}
    for _ in range(attempts):
        response = gateway.get(f"/v1/lookups/{lookup_id}", headers=_auth(subject))
        assert response.status_code == 200, response.text
        body = response.json()
        if body["status"] != "generating":
            return body
        time.sleep(delay)
    pytest.fail(f"lookup {lookup_id} stayed 'generating': {body}")


def _serve_word(
    gateway: httpx2.Client,
    word: str,
    *,
    subject: str = "reader-1",
    client_id: str | None = None,
) -> dict[str, Any]:
    """Look a word up and wait until a clip is served for it."""

    created = _create(gateway, word, client_id=client_id, subject=subject)
    assert created.status_code == 200, created.text
    body: dict[str, Any] = created.json()
    if body["status"] == "generating":
        body = _poll_until_settled(gateway, body["lookupId"], subject=subject)
    assert body["status"] == "served", body
    return body


def _served_sense(body: dict[str, Any]) -> dict[str, Any]:
    served: list[dict[str, Any]] = [
        sense for sense in body["senses"] if sense.get("clip") and sense.get("entryId")
    ]
    assert served, f"the lookup served no entry: {body}"
    return served[0]


def _served_entry_id(body: dict[str, Any]) -> str:
    return str(_served_sense(body)["entryId"])


def _served_clip_url(body: dict[str, Any]) -> str:
    return str(_served_sense(body)["clip"]["url"])


def _feedback(
    gateway: httpx2.Client,
    lookup_id: str,
    rating: str,
    *,
    subject: str = "reader-1",
    client_id: str | None = None,
) -> httpx2.Response:
    return gateway.post(
        "/v1/feedback",
        headers=_auth(subject),
        json={
            "lookupId": lookup_id,
            "rating": rating,
            "clientFeedbackId": client_id or f"fb-{uuid4().hex}",
        },
    )


def _report(
    gateway: httpx2.Client,
    lookup_id: str,
    *,
    reason: str = "offensive",
    note: str | None = None,
    subject: str = "reader-1",
    client_id: str | None = None,
) -> httpx2.Response:
    return gateway.post(
        "/v1/reports",
        headers=_auth(subject),
        json={
            "lookupId": lookup_id,
            "reason": reason,
            "note": note,
            "clientReportId": client_id or f"rp-{uuid4().hex}",
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


def _queue(
    gateway: httpx2.Client,
    *,
    word: str | None = None,
    state: str | None = None,
    reason: str | None = None,
    headers: dict[str, str] = OPERATOR,
) -> httpx2.Response:
    params: dict[str, str] = {}
    if word is not None:
        params["word"] = word
    if state is not None:
        params["state"] = state
    if reason is not None:
        params["reason"] = reason
    return gateway.get("/internal/review/queue", headers=headers, params=params)


def _entry_detail(
    gateway: httpx2.Client, entry_id: str, *, headers: dict[str, str] = OPERATOR
) -> httpx2.Response:
    return gateway.get(f"/internal/review/entries/{entry_id}", headers=headers)


def _act(
    gateway: httpx2.Client,
    entry_id: str,
    action: str,
    *,
    expected_state: str = "queued",
    chosen_clip: str | None = None,
    phrase: str | None = None,
    notes: str | None = None,
) -> httpx2.Response:
    payload: dict[str, Any] = {"action": action, "expectedState": expected_state}
    if chosen_clip is not None:
        payload["chosenClip"] = chosen_clip
    if phrase is not None:
        payload["phrase"] = phrase
    if notes is not None:
        payload["notes"] = notes
    return gateway.post(
        f"/internal/review/entries/{entry_id}/actions", headers=OPERATOR, json=payload
    )


def _library_entry(library: httpx2.Client, entry_id: str) -> httpx2.Response:
    return library.get(f"/internal/library/entries/{entry_id}", headers=INTERNAL)


def _find_entry(library: httpx2.Client, lemma: str) -> dict[str, Any] | None:
    response = library.get(
        "/internal/library/entries",
        headers=INTERNAL,
        params={"lemma": lemma, **_MEANING},
    )
    assert response.status_code == 200, response.text
    entry: dict[str, Any] | None = response.json()["entry"]
    return entry


def _wait_for_candidate(
    gateway: httpx2.Client,
    entry_id: str,
    *,
    attempts: int = 80,
    delay: float = 0.25,
) -> dict[str, Any]:
    """Wait until the report-triggered clip is held as the entry's candidate."""

    for _ in range(attempts):
        response = _entry_detail(gateway, entry_id)
        assert response.status_code == 200, response.text
        detail: dict[str, Any] = response.json()
        if detail.get("candidate") is not None:
            return detail
        time.sleep(delay)
    pytest.fail(f"no candidate clip was regenerated for entry {entry_id}")


def _wait_for_replacement(
    library: httpx2.Client,
    *,
    lemma: str,
    old_entry_id: str,
    attempts: int = 80,
    delay: float = 0.25,
) -> dict[str, Any]:
    for _ in range(attempts):
        entry = _find_entry(library, lemma)
        if entry is not None and entry["entryId"] != old_entry_id:
            return entry
        time.sleep(delay)
    pytest.fail(f"the library never replaced entry {old_entry_id} for '{lemma}'")


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


# --- FEAT-010: clip feedback (C-012) -----------------------------------------


def test_a_served_clip_can_be_marked_helpful(review_gateway: httpx2.Client) -> None:
    # FEAT-010 acceptance: a served clip the reader marks helpful is recorded
    # against the entry (C-012 202 `recorded`).
    body = _serve_word(review_gateway, "zorble")
    entry_id = _served_entry_id(body)

    response = _feedback(review_gateway, body["lookupId"], "helpful")

    assert response.status_code == 202, response.text
    assert response.json() == {"recorded": True}
    assert entry_id


def test_a_negative_rating_is_recorded_and_does_not_queue_on_its_own(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-010 acceptance: marking a clip not helpful records the response against
    # the entry and flags it; the flag is not the queue — the queue holds the
    # entry only once the repeated-negative-feedback threshold is reached.
    body = _serve_word(review_gateway, "brimbly")

    response = _feedback(review_gateway, body["lookupId"], "not_helpful")

    assert response.status_code == 202, response.text
    queued = _queue(review_gateway, word="brimbly").json()
    assert queued["items"] == [], "a single negative rating must not queue the entry"


def test_the_wrong_rating_is_refused_as_unknown_and_records_nothing(
    review_gateway: httpx2.Client, review_feedback: httpx2.Client
) -> None:
    # FEAT-010 acceptance: the rating is the one like/dislike question, so a clip
    # that showed the wrong meaning is reported rather than rated ([FEAT-011]).
    # `wrong` is therefore refused as an unknown rating — the gateway's shape
    # check and the service both refuse it — and nothing is recorded (C-012).
    body = _serve_word(review_gateway, "quorble")
    entry_id = _served_entry_id(body)
    key = f"fb-{uuid4().hex}"

    refused = _feedback(review_gateway, body["lookupId"], "wrong", client_id=key)

    assert refused.status_code == 400, refused.text

    # The refusal comes before any lookup is read: a `wrong` write naming an id
    # no lookup holds is refused the same way, while a rating that is still
    # writable on the same id is not found. The check is therefore the rating's
    # shape, not the lookup, so a refused rating cannot have touched the entry.
    missing = f"lk_{uuid4().hex}"
    unknown_lookup = _feedback(review_gateway, missing, "wrong")
    missing_lookup = _feedback(review_gateway, missing, "helpful")
    assert unknown_lookup.status_code == 400, unknown_lookup.text
    assert missing_lookup.status_code == 404, missing_lookup.text

    # Nothing was recorded: the service refuses `wrong` itself, and it too refuses
    # an unknown id as the rating's shape rather than as a missing lookup, so the
    # check precedes the read at both layers.
    direct = review_feedback.post(
        "/v1/feedback",
        headers=_auth(),
        json={"lookupId": body["lookupId"], "rating": "wrong", "clientFeedbackId": key},
    )
    direct_missing = review_feedback.post(
        "/v1/feedback",
        headers=_auth(),
        json={"lookupId": missing, "rating": "wrong", "clientFeedbackId": f"fb-{uuid4().hex}"},
    )
    assert direct.status_code == 400, direct.text
    assert direct_missing.status_code == 400, direct_missing.text

    recorded = _feedback(review_gateway, body["lookupId"], "helpful", client_id=key)
    assert recorded.status_code == 202, recorded.text
    assert recorded.json() == {"recorded": True}

    # The entry is where it was: still served, still unqueued.
    reread = review_gateway.get(f"/v1/lookups/{body['lookupId']}", headers=_auth())
    assert reread.status_code == 200, reread.text
    assert _served_entry_id(reread.json()) == entry_id
    assert _queue(review_gateway, word="quorble").json()["items"] == []


def test_repeated_negative_feedback_queues_the_entry_at_the_threshold(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-010 acceptance: when enough readers' latest ratings of an entry are
    # negative, the entry is queued for review. The threshold counts distinct
    # readers' latest ratings, so three readers each rating it not helpful queues
    # it.
    first = _serve_word(review_gateway, "plimber", subject="reader-1")
    entry_id = _served_entry_id(first)

    for index, subject in enumerate(("reader-1", "reader-2", "reader-3")):
        lookup = first if index == 0 else _serve_word(review_gateway, "plimber", subject=subject)
        assert (
            _feedback(
                review_gateway, lookup["lookupId"], "not_helpful", subject=subject
            ).status_code
            == 202
        )

    queued = _queue(review_gateway, word="plimber").json()
    assert [item["entryId"] for item in queued["items"]] == [entry_id]
    assert queued["items"][0]["reason"] == "feedback_threshold"
    assert queued["items"][0]["state"] == "queued"


def test_a_repeated_rating_from_one_reader_replaces_the_earlier_one(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-010 edge case: only one reader's latest rating of an entry counts. The
    # first reader rates it not helpful and then helpful; two more rate it not
    # helpful, so the threshold of three is not reached — the first reader's
    # withdrawn negative is not counted.
    first = _serve_word(review_gateway, "thwackle", subject="reader-1")
    assert _feedback(review_gateway, first["lookupId"], "not_helpful").status_code == 202
    assert _feedback(review_gateway, first["lookupId"], "helpful").status_code == 202

    for subject in ("reader-2", "reader-3"):
        lookup = _serve_word(review_gateway, "thwackle", subject=subject)
        assert (
            _feedback(
                review_gateway, lookup["lookupId"], "not_helpful", subject=subject
            ).status_code
            == 202
        )

    queued = _queue(review_gateway, word="thwackle").json()
    assert queued["items"] == [], "only the reader's latest rating may count"


def test_a_rating_on_a_retired_entry_is_recorded_and_changes_nothing_served(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-010 edge case: a rating on a clip whose entry has since been retired is
    # still recorded, but it changes nothing served.
    body = _serve_word(review_gateway, "frobnicate")
    entry_id = _served_entry_id(body)
    retired = review_library.patch(
        f"/internal/library/entries/{entry_id}", headers=INTERNAL, json={"status": "retired"}
    )
    assert retired.status_code == 200, retired.text

    response = _feedback(review_gateway, body["lookupId"], "not_helpful")

    assert response.status_code == 202, response.text
    assert response.json() == {"recorded": True}
    assert _library_entry(review_library, entry_id).json()["entry"]["status"] == "retired"


def test_a_phrase_lookup_rating_never_touches_the_shared_library(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-010 acceptance: a phrase clip is private to the device, so feedback on
    # it is recorded against the lookup and does not affect the shared library.
    phrase = "over the glorpish moon"
    created = _create(review_gateway, phrase)
    assert created.status_code == 200, created.text
    assert created.json()["kind"] == "phrase"

    response = _feedback(review_gateway, created.json()["lookupId"], "helpful")

    assert response.status_code == 202, response.text
    assert _find_entry(review_library, phrase) is None
    assert _queue(review_gateway, word=phrase).json()["items"] == []


def test_a_replayed_rating_is_idempotent_and_a_changed_one_conflicts(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-010 edge case: feedback queued offline and resent is recorded once; the
    # same client key with a different rating is a conflict (C-012 409). The
    # conflict needs two ratings that are still writable to exercise it.
    body = _serve_word(review_gateway, "skrimble")
    key = f"fb-{uuid4().hex}"

    first = _feedback(review_gateway, body["lookupId"], "helpful", client_id=key)
    replay = _feedback(review_gateway, body["lookupId"], "helpful", client_id=key)
    conflict = _feedback(review_gateway, body["lookupId"], "not_helpful", client_id=key)

    assert first.status_code == 202, first.text
    assert replay.status_code == 202, replay.text
    assert conflict.status_code == 409, conflict.text


def test_a_rating_needs_a_served_clip(review_gateway: httpx2.Client) -> None:
    # C-012 400: a lookup that never put a clip in front of the reader has nothing
    # to rate. A lookup without consent resolves denied and serves no clip.
    denied = _create(review_gateway, "yinther", consent=False)
    assert denied.status_code == 200, denied.text
    assert denied.json()["status"] == "denied"

    response = _feedback(review_gateway, denied.json()["lookupId"], "helpful")

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "no_clip_served"


def test_a_rating_for_an_unknown_lookup_is_not_found(review_gateway: httpx2.Client) -> None:
    response = _feedback(review_gateway, f"lk_{uuid4().hex}", "helpful")
    assert response.status_code == 404, response.text


def test_a_rating_without_a_token_is_unauthorized(review_gateway: httpx2.Client) -> None:
    body = _serve_word(review_gateway, "crandle")
    response = review_gateway.post(
        "/v1/feedback",
        json={
            "lookupId": body["lookupId"],
            "rating": "helpful",
            "clientFeedbackId": f"fb-{uuid4().hex}",
        },
    )
    assert response.status_code == 401, response.text


# --- FEAT-011: report a clip (C-013) -----------------------------------------


def test_reporting_a_served_clip_queues_and_keeps_the_entry_serving(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-011 acceptance: a report records the entry and queues it for review,
    # and the entry keeps serving the clip it already serves to other readers —
    # a report does not withdraw it before a curator has judged it (D-030).
    body = _serve_word(review_gateway, "quorvex")
    entry_id = _served_entry_id(body)
    served_url = _served_clip_url(body)

    response = _report(review_gateway, body["lookupId"], reason="offensive", note="graphic")

    assert response.status_code == 202, response.text
    assert response.json()["state"] == "queued"

    kept = _library_entry(review_library, entry_id)
    assert kept.status_code == 200, kept.text
    assert kept.json()["entry"]["status"] == "active", "a reported entry keeps serving"

    queued = _queue(review_gateway, word="quorvex").json()
    assert [item["entryId"] for item in queued["items"]] == [entry_id]
    assert queued["items"][0]["reason"] == "offensive"

    later = _serve_word(review_gateway, "quorvex", subject="reader-2")
    assert _served_entry_id(later) == entry_id, "other readers keep the entry"
    assert _served_clip_url(later) == served_url, "and the clip it was serving"


def test_a_report_regenerates_one_candidate_beside_the_serving_clip(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-011 acceptance: the report regenerates one clip for the entry, held as
    # the curator's candidate, while the entry keeps serving the clip it already
    # serves (C-015 `candidate`).
    body = _serve_word(review_gateway, "vandrel", subject="reader-1")
    entry_id = _served_entry_id(body)
    served_url = _served_clip_url(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    detail = _wait_for_candidate(review_gateway, entry_id)

    assert detail["candidate"]["url"] != served_url, "a fresh clip was regenerated"
    assert detail["entry"]["status"] == "active"
    assert detail["entry"]["clip"]["url"] == served_url, "the serving clip is unchanged"
    assert [report["reason"] for report in detail["reports"]] == ["offensive"]


def test_a_reports_regenerated_clip_reaches_the_reporting_reader(
    review_gateway: httpx2.Client,
    review_push: httpx2.Client,
    review_library: httpx2.Client,
    review_model_stub: httpx2.Client,
) -> None:
    # FEAT-011 acceptance: the regenerated clip is delivered to the reporting
    # reader, by the clip-ready notice the report's generation raises (C-008),
    # while the entry keeps serving the clip it already serves to other readers.
    review_model_stub.post("/test/reset")
    review_push.post("/test/reset")

    body = _serve_word(review_gateway, "wondermint", subject="reader-1")
    entry_id = _served_entry_id(body)
    served_url = _served_clip_url(body)

    registered = _register(review_gateway, lookup_id=body["lookupId"], token="tok-reporter")
    assert registered.status_code == 202, registered.text
    assert registered.json() == {"registered": True}

    assert _report(review_gateway, body["lookupId"]).status_code == 202

    notice = _wait_for_notice(review_push, body["lookupId"])
    assert notice["token"] == "tok-reporter"
    candidate_url = notice["notification"]["data"]["clipUrl"]
    assert candidate_url != served_url

    detail = _wait_for_candidate(review_gateway, entry_id)
    assert detail["candidate"]["url"] == candidate_url, "the notice carried the candidate"

    later = _serve_word(review_gateway, "wondermint", subject="reader-2")
    assert _served_clip_url(later) == served_url, "other readers keep the serving clip"


def test_a_duplicate_report_from_one_reader_is_refused(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-011 edge case: only one report per reader per entry is queued; a second
    # report of the same entry from the same reader is refused (C-013 409).
    body = _serve_word(review_gateway, "drovnik")

    first = _report(review_gateway, body["lookupId"])
    second = _report(review_gateway, body["lookupId"])

    assert first.status_code == 202, first.text
    assert second.status_code == 409, second.text
    assert second.json()["code"] == "already_reported"


def test_a_replayed_report_is_idempotent_and_a_changed_one_conflicts(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-011 edge case: a report queued offline and resent is recorded once; the
    # same client key with a different report is a conflict (C-013 409).
    body = _serve_word(review_gateway, "shamblewick")
    key = f"rp-{uuid4().hex}"

    first = _report(review_gateway, body["lookupId"], reason="offensive", client_id=key)
    replay = _report(review_gateway, body["lookupId"], reason="offensive", client_id=key)
    conflict = _report(review_gateway, body["lookupId"], reason="low_quality", client_id=key)

    assert first.status_code == 202, first.text
    assert replay.status_code == 202, replay.text
    assert replay.json()["reportId"] == first.json()["reportId"]
    assert conflict.status_code == 409, conflict.text


def test_a_report_on_an_entry_already_under_review_joins_the_item_and_reuses_the_candidate(
    review_gateway: httpx2.Client,
    review_model_stub: httpx2.Client,
) -> None:
    # FEAT-011 / FEAT-015 edge case: an entry reported more than once holds one
    # queue item with every report against it and reuses the one candidate the
    # first report produced, so the entry costs one generation however many
    # readers report it. The entry keeps serving between the two reports.
    review_model_stub.post("/test/reset")
    first = _serve_word(review_gateway, "morblex", subject="reader-1")
    entry_id = _served_entry_id(first)

    assert _report(review_gateway, first["lookupId"], reason="low_quality").status_code == 202

    second = _serve_word(review_gateway, "morblex", subject="reader-2")
    assert _served_entry_id(second) == entry_id, "the entry still serves after a report"
    assert (
        _report(
            review_gateway, second["lookupId"], reason="wrong_meaning", subject="reader-2"
        ).status_code
        == 202
    )

    detail = _wait_for_candidate(review_gateway, entry_id)
    candidate_url = detail["candidate"]["url"]
    # Give any erroneous second candidate generation time to land before counting.
    time.sleep(0.5)
    reread = _entry_detail(review_gateway, entry_id).json()
    assert reread["candidate"]["url"] == candidate_url, "the candidate is reused, not regenerated"

    queued = _queue(review_gateway, word="morblex").json()
    assert [item["entryId"] for item in queued["items"]] == [entry_id], "one item per entry"
    reasons = {report["reason"] for report in reread["reports"]}
    assert reasons == {"low_quality", "wrong_meaning"}, "every report joins the item"

    calls = review_model_stub.get("/test/calls").json()
    assert calls["clip"] == 2, "one generation for the word and one candidate, however many reports"


def test_a_report_on_a_phrase_lookup_has_no_shared_effect(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-011 acceptance: a phrase clip is private to the device, so reporting it
    # is recorded against the lookup and has no shared effect.
    phrase = "a walk in the brindle park"
    created = _create(review_gateway, phrase)
    assert created.status_code == 200, created.text
    assert created.json()["kind"] == "phrase"

    response = _report(review_gateway, created.json()["lookupId"])

    assert response.status_code == 202, response.text
    assert _find_entry(review_library, phrase) is None
    assert _queue(review_gateway, word=phrase).json()["items"] == []


def test_a_report_note_over_the_bound_is_refused(review_gateway: httpx2.Client) -> None:
    # C-013 400: a note over 300 characters is refused before anything is queued.
    body = _serve_word(review_gateway, "sprandle")
    response = _report(review_gateway, body["lookupId"], note="x" * 301)
    assert response.status_code == 400, response.text


def test_a_report_without_a_token_is_unauthorized(review_gateway: httpx2.Client) -> None:
    body = _serve_word(review_gateway, "brendle")
    response = review_gateway.post(
        "/v1/reports",
        json={
            "lookupId": body["lookupId"],
            "reason": "offensive",
            "clientReportId": f"rp-{uuid4().hex}",
        },
    )
    assert response.status_code == 401, response.text


# --- FEAT-015: library review console (C-014 to C-016) -----------------------


def test_the_review_surface_refuses_a_caller_without_the_curator_role(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-015 acceptance: a person without the curator role is refused and the
    # attempt is logged. No session is 401; an authenticated caller without the
    # role, and a curator without a second factor, are 403 (C-014 auth).
    no_session = _queue(review_gateway, headers={})
    plain_operator = _queue(review_gateway, headers={"Authorization": "Bearer dev:operator-1"})
    curator_without_mfa = _queue(
        review_gateway, headers={"Authorization": "Bearer dev:curator:curator-2"}
    )
    curator_with_mfa = _queue(review_gateway)

    assert no_session.status_code == 401, no_session.text
    assert plain_operator.status_code == 403, plain_operator.text
    assert curator_without_mfa.status_code == 403, curator_without_mfa.text
    assert curator_with_mfa.status_code == 200, curator_with_mfa.text


def test_a_queued_entry_shows_its_word_sense_reason_phrase_and_candidate(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-015 acceptance: a queued entry appears with its word, sense, reason,
    # and generation phrase; C-015 carries the clip serving it beside the
    # candidate regenerated for the reporting reader, and the evidence behind it.
    body = _serve_word(review_gateway, "flarnic")
    entry_id = _served_entry_id(body)
    assert (
        _report(
            review_gateway, body["lookupId"], reason="wrong_meaning", note="not that"
        ).status_code
        == 202
    )

    queued = _queue(review_gateway, word="flarnic").json()
    item = next(item for item in queued["items"] if item["entryId"] == entry_id)
    assert item["lemma"] == "flarnic"
    assert item["senseLabel"] == "meaning"
    assert item["reason"] == "wrong_meaning"
    assert item["state"] == "queued"

    detail = _wait_for_candidate(review_gateway, entry_id)
    assert detail["entry"]["entryId"] == entry_id
    assert detail["entry"]["glossPhrase"], "the generation phrase travels with the entry"
    assert detail["entry"]["status"] == "active", "an entry under review keeps serving"
    assert detail["entry"]["clip"]["resolution"] == "360p"
    assert detail["candidate"]["resolution"] == "360p"
    assert detail["reports"] == [
        {
            "reportId": detail["reports"][0]["reportId"],
            "reason": "wrong_meaning",
            "note": "not that",
            "createdAt": detail["reports"][0]["createdAt"],
        }
    ]
    assert detail["state"] == "queued"


def test_the_curator_chooses_the_serving_clip_and_resolves_the_item(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: the curator chooses the clip that is serving as the one
    # served to every reader; the entry keeps serving it and the queue item is
    # resolved (C-016 `choose` with `chosenClip=serving`).
    body = _serve_word(review_gateway, "glorpish", subject="reader-1")
    entry_id = _served_entry_id(body)
    served_url = _served_clip_url(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202
    _wait_for_candidate(review_gateway, entry_id)

    response = _act(review_gateway, entry_id, "choose", chosen_clip="serving")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "active"
    assert response.json()["state"] == "actioned"
    entry = _library_entry(review_library, entry_id).json()["entry"]
    assert entry["status"] == "active"
    assert entry["clip"]["url"] == served_url

    later = _serve_word(review_gateway, "glorpish", subject="reader-2")
    assert _served_entry_id(later) == entry_id
    assert _served_clip_url(later) == served_url

    queued = _queue(review_gateway, word="glorpish", state="queued").json()
    assert queued["items"] == [], "the resolved item leaves the open queue"


def test_the_curator_chooses_the_candidate_and_it_serves_every_reader(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: the curator chooses the candidate regenerated for the
    # reporting reader; it becomes the clip served to every reader (C-016
    # `choose` with `chosenClip=candidate`).
    body = _serve_word(review_gateway, "gribble", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202
    detail = _wait_for_candidate(review_gateway, entry_id)
    candidate_url = detail["candidate"]["url"]

    response = _act(review_gateway, entry_id, "choose", chosen_clip="candidate")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "active"
    assert response.json()["state"] == "actioned"
    entry = _library_entry(review_library, entry_id).json()["entry"]
    assert entry["status"] == "active"
    assert entry["clip"]["url"] == candidate_url, "the candidate is the serving clip now"

    later = _serve_word(review_gateway, "gribble", subject="reader-2")
    assert _served_entry_id(later) == entry_id
    assert _served_clip_url(later) == candidate_url

    queued = _queue(review_gateway, word="gribble", state="queued").json()
    assert queued["items"] == [], "the resolved item leaves the open queue"


def test_the_curator_retires_an_entry_and_the_next_lookup_regenerates(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: retiring a queued entry stops it being served and the
    # next lookup of the word generates a replacement (C-016 `retire`).
    body = _serve_word(review_gateway, "snodgrass", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    response = _act(review_gateway, entry_id, "retire")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "retired"
    assert response.json()["state"] == "actioned"

    later = _serve_word(review_gateway, "snodgrass", subject="reader-2")
    replacement = _served_entry_id(later)
    assert replacement != entry_id, "a retired entry is not served; a replacement is"


def test_the_curator_edits_the_generation_phrase_and_it_regenerates(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: editing the generation phrase records the new phrase and
    # regenerates the entry from it; the queue item stays under review (C-016
    # `edit_phrase` resolves the item as `reviewed`).
    body = _serve_word(review_gateway, "quillfeather", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    response = _act(review_gateway, entry_id, "edit_phrase", phrase="a quill on the page")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "retired"
    assert response.json()["state"] == "reviewed", "a phrase edit leaves the entry under review"

    replacement = _wait_for_replacement(review_library, lemma="quillfeather", old_entry_id=entry_id)
    assert replacement["glossPhrase"] == "a quill on the page"


def test_a_second_curator_is_told_the_entry_has_already_moved(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-015 edge case: two curators act on the same entry at once; the first
    # action stands and the second is told the entry has moved (C-016 409).
    body = _serve_word(review_gateway, "grimwold", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    first = _act(review_gateway, entry_id, "choose", chosen_clip="serving", expected_state="queued")
    second = _act(review_gateway, entry_id, "retire", expected_state="queued")

    assert first.status_code == 200, first.text
    assert second.status_code == 409, second.text
    assert second.json()["code"] == "review_conflict"


def test_the_queue_state_filter_narrows_to_the_review_state(
    review_gateway: httpx2.Client,
) -> None:
    # C-014: the queue is filterable by state; an actioned item leaves the open
    # queue and is reachable only under its own state.
    body = _serve_word(review_gateway, "wobblefin", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202
    assert _act(review_gateway, entry_id, "choose", chosen_clip="serving").status_code == 200

    open_items = _queue(review_gateway, word="wobblefin", state="queued").json()["items"]
    actioned_items = _queue(review_gateway, word="wobblefin", state="actioned").json()["items"]

    assert open_items == []
    assert [item["entryId"] for item in actioned_items] == [entry_id]


def test_the_queue_reason_filter_takes_report_reasons_only(
    review_gateway: httpx2.Client,
) -> None:
    # C-014: an item queued by the negative-feedback threshold carries
    # `feedback_threshold` as its reason, which is not a report reason, so the
    # `reason` filter never selects it.
    first = _serve_word(review_gateway, "thistlewick", subject="reader-1")
    entry_id = _served_entry_id(first)
    for index, subject in enumerate(("reader-1", "reader-2", "reader-3")):
        lookup = (
            first if index == 0 else _serve_word(review_gateway, "thistlewick", subject=subject)
        )
        assert (
            _feedback(
                review_gateway, lookup["lookupId"], "not_helpful", subject=subject
            ).status_code
            == 202
        )

    all_items = _queue(review_gateway, word="thistlewick").json()["items"]
    assert [item["entryId"] for item in all_items] == [entry_id]
    assert all_items[0]["reason"] == "feedback_threshold"

    by_report_reason = _queue(review_gateway, word="thistlewick", reason="wrong_meaning").json()
    assert by_report_reason["items"] == []


def test_an_entry_with_nothing_queued_is_not_found(review_gateway: httpx2.Client) -> None:
    # C-015 404: an entry with nothing queued has no review detail.
    body = _serve_word(review_gateway, "bramblewick")
    entry_id = _served_entry_id(body)

    response = _entry_detail(review_gateway, entry_id)

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "review_entry_not_found"


def test_an_unknown_review_action_is_refused(review_gateway: httpx2.Client) -> None:
    # C-016 400: an unknown action, a choose without a clip, and an edit_phrase
    # without a phrase are refused before anything is recorded.
    body = _serve_word(review_gateway, "clotterby", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    unknown = _act(review_gateway, entry_id, "obliterate")
    missing_clip = _act(review_gateway, entry_id, "choose")
    missing_phrase = _act(review_gateway, entry_id, "edit_phrase")

    assert unknown.status_code == 400, unknown.text
    assert missing_clip.status_code == 400, missing_clip.text
    assert missing_clip.json()["code"] == "invalid_request"
    assert missing_phrase.status_code == 400, missing_phrase.text
    assert missing_phrase.json()["code"] == "invalid_request"


def test_curator_notes_over_the_bound_are_refused(review_gateway: httpx2.Client) -> None:
    # C-016 400: a curator note over 500 characters is refused.
    body = _serve_word(review_gateway, "plumbago", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    response = _act(review_gateway, entry_id, "retire", notes="x" * 501)

    assert response.status_code == 400, response.text
    assert response.json()["code"] == "invalid_request"
