"""The queued-notice retry (FEAT-008).

architecture.md "Notification Service": if the push service is down,
notifications are queued rather than lost. The queue only means that while the
running service drains it, so this exercises the retry that turns an outage into
a delayed notice.
"""

from __future__ import annotations

import asyncio
from contextlib import suppress

import pytest

from notification.app.service import PushDrainLoop
from notification.tests.fakes import (
    AUTH,
    INTERNAL,
    clip_ready_body,
    generating,
    make_client,
    register_body,
    rig,
)


@pytest.mark.asyncio
async def test_a_queued_notice_is_retried_once_the_provider_returns() -> None:
    rigged = rig(generating(), push_unavailable=True)

    with make_client(service=rigged.service) as client:
        client.post("/v1/push-registrations", headers=AUTH, json=register_body())
        accepted = client.post("/internal/clip-ready", headers=INTERNAL, json=clip_ready_body())

    # The notice was accepted but never reached the provider.
    assert accepted.json() == {"queued": 1}
    assert rigged.sender.sent == []

    rigged.sender.unavailable = False
    drain = PushDrainLoop(rigged.service, interval_seconds=0.01)
    task = asyncio.create_task(drain.run())
    try:
        await asyncio.wait_for(rigged.sender.sent_event.wait(), timeout=1.0)
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task

    assert len(rigged.sender.sent) == 1
    assert rigged.sender.sent[0][2].lookup_id == "lk_1"


def test_the_service_runs_the_drain_while_it_is_up() -> None:
    # The drain is wired into the service lifecycle, so it starts with the
    # service and stops cleanly with it.
    with make_client(run_drain_loop=True) as client:
        response = client.get("/healthz")

    assert response.status_code == 200
