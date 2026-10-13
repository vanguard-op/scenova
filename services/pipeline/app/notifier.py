"""Notification port for a finished clip (FEAT-008).

When a clip finishes after the reader's wait, the pipeline tells the notification
service so the reader can be told it is ready. The notification service ships in
a later phase, so the default port only logs the identifiers — never the word or
phrase, which are not carried here.
"""

from __future__ import annotations

import logging
from typing import Protocol

from .clip_client import ClipResult

logger = logging.getLogger(__name__)


class Notifier(Protocol):
    """Port for telling the reader a clip is ready."""

    async def clip_ready(self, *, lookup_id: str, job_id: str, clip: ClipResult) -> None: ...


class LoggingNotifier:
    """A placeholder notifier that records the ready event without a payload."""

    async def clip_ready(self, *, lookup_id: str, job_id: str, clip: ClipResult) -> None:
        logger.info("clip ready for lookup %s (job %s)", lookup_id, job_id)
