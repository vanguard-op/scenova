"""Port to the generation pipeline for a report candidate and a phrase edit.

A report triggers one generation for the entry: the pipeline produces a fresh
clip and holds it as the entry's candidate, and the reporting reader is served
it (FEAT-011). The job carries the entry, and the reporting reader's lookup so
the finished clip's notice reaches them; the pipeline recognises the review
route from the job's lookup id. A curator's `edit_phrase` regenerates the entry
from the curator's phrase (FEAT-015).

The job id is derived from the entry and a nonce, so a retried action does not
enqueue a second generation while a fresh review cycle gets a fresh job; the
pipeline's 409 for a repeated id is read as already-enqueued rather than an
error. An unreachable pipeline is reported as the review service being
unavailable (C-016 503).
"""

from __future__ import annotations

import hashlib
from collections.abc import Mapping
from typing import Protocol

import httpx2

# Clips are capped at four seconds, so a regeneration targets the cap, matching
# the lookup path's own generation request.
CLIP_TARGET_SECONDS = 4.0

# The review route the pipeline recognises in a job's lookup id; the format is
# shared with the pipeline and is internal, not a numbered contract.
_CANDIDATE_PREFIX = "cand:"
_REPLACEMENT_PREFIX = "edit:"


class RegenerationUnavailableError(Exception):
    """The generation pipeline could not accept the regeneration job."""


class RegenerationTrigger(Protocol):
    """Hands a report candidate or a phrase-edit job to the pipeline (C-003)."""

    async def generate_candidate(
        self,
        *,
        entry_id: str,
        reader_lookup_id: str | None,
        lemma: str,
        sense_label: str,
        part_of_speech: str,
        nonce: str,
    ) -> None: ...

    async def regenerate(
        self,
        *,
        entry_id: str,
        lemma: str,
        sense_label: str,
        part_of_speech: str,
        phrase: str | None,
    ) -> None: ...

    async def aclose(self) -> None: ...


def candidate_job_id(entry_id: str, nonce: str) -> str:
    """A stable job id for one review cycle's candidate generation."""

    key = f"candidate:{entry_id}:{nonce}"
    return "gen_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]


def regeneration_job_id(entry_id: str, phrase: str | None) -> str:
    """A stable job id for one entry's phrase-edit regeneration."""

    key = f"review:{entry_id}:{phrase or ''}"
    return "gen_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]


def candidate_lookup_id(entry_id: str, reader_lookup_id: str | None) -> str:
    """The lookup id a report candidate job carries (mirrors the pipeline)."""

    if reader_lookup_id is None:
        return f"{_CANDIDATE_PREFIX}{entry_id}"
    return f"{_CANDIDATE_PREFIX}{entry_id}:{reader_lookup_id}"


def replacement_lookup_id(entry_id: str) -> str:
    """The lookup id a curator's phrase-edit job carries (mirrors the pipeline)."""

    return f"{_REPLACEMENT_PREFIX}{entry_id}"


class HttpRegenerationTrigger:
    """Calls the generation pipeline over HTTP with the internal audience."""

    def __init__(
        self,
        *,
        base_url: str,
        internal_audience: str,
        clip_model_pin: str,
        timeout_seconds: float = 5.0,
        transport: httpx2.AsyncBaseTransport | None = None,
    ) -> None:
        self._internal_audience = internal_audience
        self._clip_model_pin = clip_model_pin
        self._client = httpx2.AsyncClient(
            base_url=base_url.rstrip("/"),
            timeout=timeout_seconds,
            transport=transport,
        )

    async def generate_candidate(
        self,
        *,
        entry_id: str,
        reader_lookup_id: str | None,
        lemma: str,
        sense_label: str,
        part_of_speech: str,
        nonce: str,
    ) -> None:
        payload = {
            "jobId": candidate_job_id(entry_id, nonce),
            "lookupId": candidate_lookup_id(entry_id, reader_lookup_id),
            "kind": "word",
            "lemma": lemma,
            "phrase": None,
            "senseLabel": sense_label,
            "partOfSpeech": part_of_speech,
            "targetDurationSeconds": CLIP_TARGET_SECONDS,
            "modelPin": self._clip_model_pin,
            "attempt": 0,
        }
        await self._enqueue(payload)

    async def regenerate(
        self,
        *,
        entry_id: str,
        lemma: str,
        sense_label: str,
        part_of_speech: str,
        phrase: str | None,
    ) -> None:
        payload = {
            "jobId": regeneration_job_id(entry_id, phrase),
            "lookupId": replacement_lookup_id(entry_id),
            "kind": "word",
            "lemma": lemma,
            "phrase": phrase,
            "senseLabel": sense_label,
            "partOfSpeech": part_of_speech,
            "targetDurationSeconds": CLIP_TARGET_SECONDS,
            "modelPin": self._clip_model_pin,
            "attempt": 0,
        }
        await self._enqueue(payload)

    async def _enqueue(self, payload: Mapping[str, object]) -> None:
        try:
            response = await self._client.post(
                "/internal/generation-jobs",
                headers={"x-internal-audience": self._internal_audience},
                json=payload,
            )
        except httpx2.HTTPError as exc:
            raise RegenerationUnavailableError("The generation pipeline is unreachable.") from exc

        if response.status_code in (202, 409):
            # 409 means a job with this id is already enqueued; the generation
            # it will produce is the one the caller asked for.
            return
        raise RegenerationUnavailableError("The generation pipeline could not accept the job.")

    async def aclose(self) -> None:
        await self._client.aclose()
