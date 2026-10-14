"""Port to the generation pipeline for a curator's replace and edit_phrase (C-016).

`replace` retires an entry and regenerates it; `edit_phrase` records a new
generation phrase and regenerates the entry from it. Both hand a word job to the
pipeline (C-003) so a replacement clip is produced off the curator's path. A word
job normally leaves the phrase null and the pipeline generates the gloss phrase
itself; a curator's edit supplies the phrase the clip is generated from.

The job id is derived from the entry and the phrase, so a retried action does not
enqueue a second generation; the pipeline's 409 for a repeated id is read as
already-enqueued rather than an error. An unreachable pipeline is reported as the
review service being unavailable (C-016 503).
"""

from __future__ import annotations

import hashlib
from typing import Protocol

import httpx2

# Clips are capped at four seconds, so a regeneration targets the cap, matching
# the lookup path's own generation request.
CLIP_TARGET_SECONDS = 4.0


class RegenerationUnavailableError(Exception):
    """The generation pipeline could not accept the regeneration job."""


class RegenerationTrigger(Protocol):
    """Hands a regeneration job to the generation pipeline (C-003)."""

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


def regeneration_job_id(entry_id: str, phrase: str | None) -> str:
    """A stable job id for one entry's regeneration, salted by the phrase.

    A retried action computes the same id, so the pipeline's 409 dedupes it; an
    edit to a different phrase is a different job.
    """

    key = f"review:{entry_id}:{phrase or ''}"
    return "gen_" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:32]


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
            "lookupId": f"review:{entry_id}",
            "kind": "word",
            "lemma": lemma,
            "phrase": phrase,
            "senseLabel": sense_label,
            "partOfSpeech": part_of_speech,
            "targetDurationSeconds": CLIP_TARGET_SECONDS,
            "modelPin": self._clip_model_pin,
            "attempt": 0,
        }
        try:
            response = await self._client.post(
                "/internal/generation-jobs",
                headers={"x-internal-audience": self._internal_audience},
                json=payload,
            )
        except httpx2.HTTPError as exc:
            raise RegenerationUnavailableError("The generation pipeline is unreachable.") from exc

        if response.status_code in (202, 409):
            # 409 means a job with this id is already enqueued; the regeneration
            # it will produce is the one the curator asked for.
            return
        raise RegenerationUnavailableError("The generation pipeline could not accept the job.")

    async def aclose(self) -> None:
        await self._client.aclose()
