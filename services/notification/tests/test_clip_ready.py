"""Clip-ready notice tests: delivery, idempotency, and queueing (FEAT-008)."""

from __future__ import annotations

import asyncio

from notification.app.lookups import LookupStatus
from notification.tests.fakes import (
    AUTH,
    INTERNAL,
    SUBJECT,
    clip_descriptor,
    clip_ready_body,
    generating,
    make_client,
    register_body,
    rig,
)


def test_a_registered_device_is_notified_when_the_clip_is_ready() -> None:
    rigged = rig(generating())

    with make_client(service=rigged.service) as client:
        client.post("/v1/push-registrations", headers=AUTH, json=register_body())
        response = client.post("/internal/clip-ready", headers=INTERNAL, json=clip_ready_body())

    assert response.status_code == 202
    assert response.json() == {"queued": 1}
    assert len(rigged.sender.sent) == 1
    token, platform, notice = rigged.sender.sent[0]
    assert token == "fcm-token-1"
    assert platform.value == "android"
    assert notice.lookup_id == "lk_1"
    assert notice.job_id == "job_1"
    assert notice.clip_url == "https://cdn.example/clip_1.mp4"


def test_a_repeated_job_id_is_not_notified_twice() -> None:
    rigged = rig(generating())

    with make_client(service=rigged.service) as client:
        client.post("/v1/push-registrations", headers=AUTH, json=register_body())
        first = client.post("/internal/clip-ready", headers=INTERNAL, json=clip_ready_body())
        second = client.post("/internal/clip-ready", headers=INTERNAL, json=clip_ready_body())

    assert first.json() == {"queued": 1}
    assert second.json() == {"queued": 0}
    assert len(rigged.sender.sent) == 1


def test_a_push_outage_queues_the_notice_and_drains_it_later() -> None:
    rigged = rig(generating(), push_unavailable=True)

    with make_client(service=rigged.service) as client:
        client.post("/v1/push-registrations", headers=AUTH, json=register_body())
        response = client.post("/internal/clip-ready", headers=INTERNAL, json=clip_ready_body())

    # The notice was accepted but never reached the provider.
    assert response.json() == {"queued": 1}
    assert rigged.sender.sent == []

    # When the provider comes back, the queued notice is delivered rather than lost.
    rigged.sender.unavailable = False
    delivered = asyncio.run(rigged.service.drain_pending())

    assert delivered == 1
    assert len(rigged.sender.sent) == 1
    assert rigged.sender.sent[0][2].lookup_id == "lk_1"


def test_a_clip_ready_with_no_registration_sends_nothing() -> None:
    rigged = rig()

    with make_client(service=rigged.service) as client:
        response = client.post("/internal/clip-ready", headers=INTERNAL, json=clip_ready_body())

    assert response.status_code == 202
    assert response.json() == {"queued": 0}
    assert rigged.sender.sent == []


def test_a_served_lookups_regenerated_clip_reaches_the_reporting_reader() -> None:
    # FEAT-011: a report of a served clip regenerates one for the reporting
    # reader, and the notice is how it reaches them. The device registered
    # against the served lookup, and the regenerated clip's notice is delivered
    # to it while the entry keeps serving everyone else.
    statuses = {("lk_1", SUBJECT): LookupStatus.SERVED}
    rigged = rig(statuses)
    regenerated = clip_descriptor(url="https://cdn.example/candidate_1.mp4")

    with make_client(service=rigged.service) as client:
        registered = client.post("/v1/push-registrations", headers=AUTH, json=register_body())
        ready = client.post(
            "/internal/clip-ready",
            headers=INTERNAL,
            json=clip_ready_body(jobId="job_candidate", clip=regenerated),
        )

    assert registered.json() == {"registered": True}
    assert ready.json() == {"queued": 1}
    assert len(rigged.sender.sent) == 1
    notice = rigged.sender.sent[0][2]
    assert notice.lookup_id == "lk_1"
    assert notice.job_id == "job_candidate"
    assert notice.clip_url == "https://cdn.example/candidate_1.mp4"


def test_the_clip_ready_route_rejects_a_missing_audience() -> None:
    with make_client() as client:
        response = client.post("/internal/clip-ready", json=clip_ready_body())

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_a_clip_over_the_four_second_cap_is_refused() -> None:
    body = clip_ready_body(clip=clip_descriptor(durationSeconds=5.0))

    with make_client() as client:
        response = client.post("/internal/clip-ready", headers=INTERNAL, json=body)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"
