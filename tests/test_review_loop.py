"""Integration and acceptance tests for the trust-and-continuity loop.

Verifies FEAT-010 (clip feedback, C-012), FEAT-011 (report a clip, C-013), and
FEAT-015 (library review console, C-014 to C-016) end to end across the shipped
services: a reader looks a word up, is served a clip from the shared library, rates
or reports it through the gateway, the entry is queued and held, and a curator
works the queue and moves the entry.

The stack boots the feedback service beside the lookup, library, and pipeline
services (the services the C-012 to C-016 contracts name), with the model provider
as a local double so a word lookup actually produces a clip to rate and report.
Each test uses its own invented word, so the shared library, lookup store, and
review queue carry no state between tests.
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


def _served_entry_id(body: dict[str, Any]) -> str:
    served: list[str] = [
        sense["entryId"] for sense in body["senses"] if sense.get("clip") and sense.get("entryId")
    ]
    assert served, f"the lookup served no entry: {body}"
    return served[0]


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
    phrase: str | None = None,
    notes: str | None = None,
) -> httpx2.Response:
    payload: dict[str, Any] = {"action": action, "expectedState": expected_state}
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
    # FEAT-010 acceptance: marking a clip wrong records the response against the
    # entry and flags it; the flag is not the queue — the queue holds the entry
    # only once the repeated-negative-feedback threshold is reached.
    body = _serve_word(review_gateway, "brimbly")

    response = _feedback(review_gateway, body["lookupId"], "wrong")

    assert response.status_code == 202, response.text
    queued = _queue(review_gateway, word="brimbly").json()
    assert queued["items"] == [], "a single negative rating must not queue the entry"


def test_repeated_negative_feedback_queues_the_entry_at_the_threshold(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-010 acceptance: when enough readers' latest ratings of an entry are
    # negative, the entry is queued for review. The threshold counts distinct
    # readers' latest ratings, so three readers each rating it wrong queues it.
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
    # first reader rates it wrong and then helpful; two more rate it wrong, so the
    # threshold of three is not reached — the first reader's withdrawn negative is
    # not counted.
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
    # same client key with a different rating is a conflict (C-012 409).
    body = _serve_word(review_gateway, "skrimble")
    key = f"fb-{uuid4().hex}"

    first = _feedback(review_gateway, body["lookupId"], "helpful", client_id=key)
    replay = _feedback(review_gateway, body["lookupId"], "helpful", client_id=key)
    conflict = _feedback(review_gateway, body["lookupId"], "wrong", client_id=key)

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


def test_reporting_a_served_clip_queues_and_holds_the_entry(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-011 acceptance: a report records the entry and queues it for review,
    # and holds the reported clip from new readers until it is reviewed.
    body = _serve_word(review_gateway, "quorvex")
    entry_id = _served_entry_id(body)

    response = _report(review_gateway, body["lookupId"], reason="offensive", note="graphic")

    assert response.status_code == 202, response.text
    assert response.json()["status"] == "queued"

    held = _library_entry(review_library, entry_id)
    assert held.status_code == 200, held.text
    assert held.json()["entry"]["status"] == "held", "a reported entry is held from new readers"

    queued = _queue(review_gateway, word="quorvex").json()
    assert [item["entryId"] for item in queued["items"]] == [entry_id]
    assert queued["items"][0]["reason"] == "offensive"


def test_a_reported_clip_is_not_served_to_a_new_reader(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-011 acceptance: the reported clip is held from new readers. A later
    # reader's lookup does not serve it; the entry is superseded by a replacement.
    body = _serve_word(review_gateway, "vandrel", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    later = _serve_word(review_gateway, "vandrel", subject="reader-2")

    assert entry_id not in {sense.get("entryId") for sense in later["senses"]}
    assert (
        _library_entry(review_library, entry_id).status_code == 404
    ), "the reported entry no longer exists once a replacement is generated"


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


def test_a_report_on_an_entry_already_under_review_joins_the_same_item(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-011 / FEAT-015 edge case: an entry reported more than once holds one
    # queue item with every report against it. Both readers are served the entry
    # before the first report holds it; a lookup made after the hold is a fresh
    # generation, so the second report must come from an already-served lookup.
    first = _serve_word(review_gateway, "morblex", subject="reader-1")
    entry_id = _served_entry_id(first)
    second = _serve_word(review_gateway, "morblex", subject="reader-2")
    assert _served_entry_id(second) == entry_id, "both readers are served the same entry"

    assert _report(review_gateway, first["lookupId"], reason="low_quality").status_code == 202
    assert (
        _report(
            review_gateway, second["lookupId"], reason="wrong_meaning", subject="reader-2"
        ).status_code
        == 202
    )

    queued = _queue(review_gateway, word="morblex").json()
    assert [item["entryId"] for item in queued["items"]] == [entry_id], "one item per entry"

    detail = _entry_detail(review_gateway, entry_id).json()
    reasons = {report["reason"] for report in detail["reports"]}
    assert reasons == {"low_quality", "wrong_meaning"}, "every report joins the item"


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


def test_a_queued_entry_shows_its_word_sense_reason_and_phrase(
    review_gateway: httpx2.Client,
) -> None:
    # FEAT-015 acceptance: a queued entry appears with its word, sense, reason,
    # and generation phrase; C-015 carries the clip and the evidence behind it.
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

    detail = _entry_detail(review_gateway, entry_id).json()
    assert detail["entry"]["entryId"] == entry_id
    assert detail["entry"]["glossPhrase"], "the generation phrase travels with the entry"
    assert detail["entry"]["status"] == "held"
    assert detail["entry"]["clip"]["resolution"] == "360p"
    assert detail["reports"] == [
        {
            "reportId": detail["reports"][0]["reportId"],
            "reason": "wrong_meaning",
            "note": "not that",
            "createdAt": detail["reports"][0]["createdAt"],
        }
    ]
    assert detail["state"] == "queued"


def test_the_curator_clears_an_entry_and_it_returns_to_serving(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: clearing a queued entry returns it to serving and
    # resolves its queue item (C-016 `clear`).
    body = _serve_word(review_gateway, "glorpish", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    response = _act(review_gateway, entry_id, "clear")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "active"
    assert response.json()["state"] == "actioned"
    assert _library_entry(review_library, entry_id).json()["entry"]["status"] == "active"

    later = _serve_word(review_gateway, "glorpish", subject="reader-2")
    assert _served_entry_id(later) == entry_id, "a cleared entry is served again"

    queued = _queue(review_gateway, word="glorpish", state="queued").json()
    assert queued["items"] == [], "the resolved item leaves the open queue"


def test_the_curator_holds_an_entry_and_it_is_withheld(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: holding a queued entry withholds it from new readers
    # until it is cleared or replaced (C-016 `hold`).
    body = _serve_word(review_gateway, "dremmel", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    response = _act(review_gateway, entry_id, "hold")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "held"
    assert response.json()["state"] == "actioned"
    assert _library_entry(review_library, entry_id).json()["entry"]["status"] == "held"

    later = _serve_word(review_gateway, "dremmel", subject="reader-2")
    assert entry_id not in {sense.get("entryId") for sense in later["senses"]}


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


def test_the_curator_replaces_an_entry_and_it_regenerates(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: replacing a queued entry retires it and regenerates it
    # (C-016 `replace`).
    body = _serve_word(review_gateway, "hobblecrank", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    response = _act(review_gateway, entry_id, "replace")

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "retired"
    assert response.json()["state"] == "actioned"

    replacement = _wait_for_replacement(review_library, lemma="hobblecrank", old_entry_id=entry_id)
    assert replacement["status"] == "active"


def test_the_curator_edits_the_generation_phrase_and_it_regenerates(
    review_gateway: httpx2.Client, review_library: httpx2.Client
) -> None:
    # FEAT-015 acceptance: editing the generation phrase records the new phrase and
    # regenerates the entry from it (C-016 `edit_phrase`).
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

    first = _act(review_gateway, entry_id, "clear", expected_state="queued")
    second = _act(review_gateway, entry_id, "retire", expected_state="queued")

    assert first.status_code == 200, first.text
    assert second.status_code == 409, second.text
    assert second.json()["code"] == "review_conflict"


def test_an_entry_with_nothing_queued_is_not_found(review_gateway: httpx2.Client) -> None:
    # C-015 404: an entry with nothing queued has no review detail.
    body = _serve_word(review_gateway, "bramblewick")
    entry_id = _served_entry_id(body)

    response = _entry_detail(review_gateway, entry_id)

    assert response.status_code == 404, response.text
    assert response.json()["code"] == "review_entry_not_found"


def test_an_unknown_review_action_is_refused(review_gateway: httpx2.Client) -> None:
    # C-016 400: an unknown action, and an edit_phrase without a phrase, are
    # refused before anything is recorded.
    body = _serve_word(review_gateway, "clotterby", subject="reader-1")
    entry_id = _served_entry_id(body)
    assert _report(review_gateway, body["lookupId"]).status_code == 202

    unknown = _act(review_gateway, entry_id, "obliterate")
    missing_phrase = _act(review_gateway, entry_id, "edit_phrase")

    assert unknown.status_code == 400, unknown.text
    assert missing_phrase.status_code == 400, missing_phrase.text
    assert missing_phrase.json()["code"] == "invalid_request"
