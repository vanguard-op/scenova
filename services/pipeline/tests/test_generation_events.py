"""Generation lifecycle event tests (EVT-007 to EVT-009).

Covers the taxonomy's key properties for each generation event, the failure
reason for every outcome, that a deliberate stop is not recorded as a failure,
and that no event carries the phrase.
"""

from __future__ import annotations

import json
import logging

import pytest

from pipeline.app.clip_client import ClipDeclinedError, ClipTimeoutError, ClipUnavailableError
from pipeline.app.events import (
    GENERATION_COMPLETED,
    GENERATION_FAILED,
    GENERATION_STARTED,
    REASON_DURATION_OVER_CAP,
    REASON_DURATION_UNDER_FLOOR,
    REASON_PROVIDER_DECLINED,
    REASON_PROVIDER_TIMEOUT,
    REASON_PROVIDER_UNAVAILABLE,
    GenerationEvent,
    LoggingGenerationEventEmitter,
    generation_failed,
)
from pipeline.app.models import Kind
from pipeline.tests.fakes import FakeClipGenerator, FakeClock, clip, request, rig

_MODEL = "gemini-omni-1.1-flash"


@pytest.mark.asyncio
async def test_a_successful_job_records_started_then_completed() -> None:
    test_rig = rig(clock=FakeClock(10.0, 11.25))
    await test_rig.service.submit(request(), "corr-1")

    await test_rig.service.run("job-1")

    started, completed = test_rig.events.events
    assert [started.name, completed.name] == [GENERATION_STARTED, GENERATION_COMPLETED]
    assert started.properties == {"kind": "word", "model_version": _MODEL}
    assert completed.properties == {
        "model_version": _MODEL,
        "duration_ms": 1250,
        "cost_units": 1.0,
        "resolution": "360p",
    }
    assert completed.correlation_id == "corr-1"
    assert completed.job_id == "job-1"
    assert completed.lookup_id == "lk_1"


@pytest.mark.asyncio
async def test_a_phrase_job_records_the_phrase_kind() -> None:
    test_rig = rig()
    await test_rig.service.submit(request(kind=Kind.PHRASE, lemma=None, phrase="kick the bucket"))

    await test_rig.service.run("job-1")

    assert test_rig.events.events[0].properties["kind"] == "phrase"


@pytest.mark.asyncio
async def test_a_declined_phrase_records_the_provider_declined_reason() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipDeclinedError("declined")))
    await test_rig.service.submit(request())

    await test_rig.service.run("job-1")

    failed = test_rig.events.events[-1]
    assert failed.name == GENERATION_FAILED
    assert failed.properties == {"reason": REASON_PROVIDER_DECLINED, "model_version": _MODEL}


@pytest.mark.asyncio
async def test_a_timeout_records_the_provider_timeout_reason() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipTimeoutError("timeout")))
    await test_rig.service.submit(request())

    await test_rig.service.run("job-1")

    assert test_rig.events.events[-1].properties["reason"] == REASON_PROVIDER_TIMEOUT


@pytest.mark.asyncio
async def test_an_unavailable_provider_records_the_provider_unavailable_reason() -> None:
    test_rig = rig(generator=FakeClipGenerator(error=ClipUnavailableError("down")))
    await test_rig.service.submit(request())

    await test_rig.service.run("job-1")

    assert test_rig.events.events[-1].properties["reason"] == REASON_PROVIDER_UNAVAILABLE


@pytest.mark.asyncio
async def test_a_clip_over_the_cap_records_the_duration_reason() -> None:
    test_rig = rig(generator=FakeClipGenerator(result=clip(duration_seconds=4.5)))
    await test_rig.service.submit(request())

    await test_rig.service.run("job-1")

    assert test_rig.events.events[-1].properties["reason"] == REASON_DURATION_OVER_CAP


@pytest.mark.asyncio
async def test_a_clip_below_the_floor_records_the_duration_reason() -> None:
    test_rig = rig(generator=FakeClipGenerator(result=clip(duration_seconds=2.5)))
    await test_rig.service.submit(request())

    await test_rig.service.run("job-1")

    assert test_rig.events.events[-1].properties["reason"] == REASON_DURATION_UNDER_FLOOR


@pytest.mark.asyncio
async def test_the_kill_switch_records_no_generation_event() -> None:
    # A stop by the flag is not a generation that failed, so it must not feed
    # the generation-failure rate that itself disables `enable_generation`.
    test_rig = rig(enable_generation=False)
    await test_rig.service.submit(request())

    await test_rig.service.run("job-1")

    assert test_rig.events.events == []


@pytest.mark.asyncio
async def test_an_exhausted_budget_records_no_generation_event() -> None:
    test_rig = rig(budget=1.0)
    await test_rig.service.submit(request("job-1"))
    await test_rig.service.submit(request("job-2", lookup_id="lk_2"))

    await test_rig.service.run("job-1")
    await test_rig.service.run("job-2")

    # Only the admitted job is recorded; the throttled one is a capacity
    # decision, not a provider failure.
    assert [event.name for event in test_rig.events.events] == [
        GENERATION_STARTED,
        GENERATION_COMPLETED,
    ]


@pytest.mark.asyncio
async def test_a_job_without_a_correlation_id_gets_one() -> None:
    test_rig = rig()
    await test_rig.service.submit(request())

    job = await test_rig.queue.get("job-1")

    assert job is not None
    assert job.correlation_id


@pytest.mark.asyncio
async def test_an_event_record_carries_no_phrase() -> None:
    test_rig = rig()
    await test_rig.service.submit(request(phrase="a secret phrase"))

    await test_rig.service.run("job-1")

    payload = json.dumps([event.to_log_record() for event in test_rig.events.events])
    assert "a secret phrase" not in payload


def test_an_off_taxonomy_property_is_refused() -> None:
    with pytest.raises(ValueError):
        GenerationEvent(
            name=GENERATION_FAILED,
            correlation_id="corr-1",
            job_id="job-1",
            lookup_id="lk_1",
            properties={"reason": "provider_timeout", "email": "reader@example.com"},
        )


def test_the_log_emitter_writes_the_structured_event_field(
    caplog: pytest.LogCaptureFixture,
) -> None:
    emitter = LoggingGenerationEventEmitter()
    event = generation_failed(
        correlation_id="corr-1",
        job_id="job-1",
        lookup_id="lk_1",
        reason=REASON_PROVIDER_TIMEOUT,
        model_version=_MODEL,
    )

    with caplog.at_level(logging.INFO, logger="pipeline.app.events"):
        emitter.emit(event)

    record = json.loads(caplog.records[0].getMessage())
    assert record["event"] == GENERATION_FAILED
    assert record["reason"] == REASON_PROVIDER_TIMEOUT
    assert record["model_version"] == _MODEL
    assert record["correlation_id"] == "corr-1"
