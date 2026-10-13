"""Registration and clip-ready notice delivery (FEAT-008, C-008).

`register` binds a device's push token to the lookup the reader is waiting on.
The lookup must be one the reader owns and that is still generating: an unknown
lookup is refused as a bad request, and a lookup that has already resolved needs
no notice, so `registered` reports false rather than holding a token for an
event that will never come.

`clip_ready` is the internal call the generation pipeline makes when a clip
finishes (architecture "Notification Service": `Gen --> Notify`). It sends one
notice per registered device; a push provider that cannot be reached leaves the
notice queued rather than lost, and `drain_pending` retries the queue once the
provider is back. Each finished job is claimed once, so a retried ingest never
sends a second notice.
"""

from __future__ import annotations

import logging
from collections import deque

from .config import Settings
from .errors import UnknownLookupError, UnreadableTokenError
from .lookups import HttpLookupDirectory, LookupDirectory, LookupStatus, LookupUnavailableError
from .models import (
    ClipReadyRequest,
    ClipReadyResponse,
    RegisterRequest,
    RegisterResponse,
)
from .push import (
    ClipReadyNotice,
    HttpPushSender,
    LoggingPushSender,
    PushSender,
    PushUnavailableError,
)
from .store import InMemoryRegistrationStore, PushRegistration, RegistrationStore

logger = logging.getLogger(__name__)

# A platform push token is dense printable ASCII with no spaces. A populated
# string inside this bound is treated as readable; anything else is refused
# rather than stored, so an empty or mangled token never becomes a dead
# registration.
_MAX_TOKEN_LENGTH = 4096


class NotificationService:
    """Records push registrations and tells the reader a clip is ready."""

    def __init__(
        self,
        *,
        store: RegistrationStore,
        lookups: LookupDirectory,
        sender: PushSender,
        pending_limit: int = 1000,
    ) -> None:
        self._store = store
        self._lookups = lookups
        self._sender = sender
        self._pending_limit = max(1, pending_limit)
        # Notices the provider could not take, oldest first. In memory for the
        # reading phase; the queue store replaces it behind the same seam.
        self._pending: deque[tuple[PushRegistration, ClipReadyNotice]] = deque()

    async def register(self, request: RegisterRequest, subject: str) -> RegisterResponse:
        """Record a device for a lookup, or report that no notice is coming.

        The lookup is confirmed against its owner before the token is stored. A
        lookup service that cannot be reached yields `registered=false` rather
        than a claim the service cannot honour; a lookup the reader does not own
        is refused.
        """

        token = request.token.strip()
        if not _readable_token(token):
            raise UnreadableTokenError("That device token could not be read.")
        try:
            status = await self._lookups.status(request.lookupId, subject)
        except LookupUnavailableError:
            logger.warning(
                "the lookup service could not confirm lookup %s; the registration was not held",
                request.lookupId,
            )
            return RegisterResponse(registered=False)
        if status is None:
            raise UnknownLookupError("No lookup was found for this id.")
        if status is not LookupStatus.GENERATING:
            # The clip is already served, or none is coming (a fallback or a
            # denial). There is no later event to notify about.
            return RegisterResponse(registered=False)
        await self._store.add(
            PushRegistration(
                token=token,
                platform=request.platform,
                subject=subject,
                lookup_id=request.lookupId,
            )
        )
        return RegisterResponse(registered=True)

    async def clip_ready(self, request: ClipReadyRequest) -> ClipReadyResponse:
        """Tell every device waiting on a lookup that its clip is ready.

        One notice per registered device, queued when the provider is down, and
        at most once per job.
        """

        if not await self._store.claim(request.jobId):
            return ClipReadyResponse(queued=0)
        registrations = await self._store.take(request.lookupId)
        notice = ClipReadyNotice(
            lookup_id=request.lookupId,
            job_id=request.jobId,
            clip_url=request.clip.url,
            duration_seconds=request.clip.durationSeconds,
            resolution=request.clip.resolution,
            has_audio=request.clip.hasAudio,
        )
        queued = 0
        for registration in registrations:
            queued += 1
            await self._deliver_or_queue(registration, notice)
        return ClipReadyResponse(queued=queued)

    async def drain_pending(self) -> int:
        """Retry queued notices; stop at the first provider that is still down.

        Returns how many notices reached the provider, so a drain can be
        observed.
        """

        delivered = 0
        while self._pending:
            registration, notice = self._pending[0]
            try:
                await self._sender.send(
                    token=registration.token,
                    platform=registration.platform,
                    notice=notice,
                )
            except PushUnavailableError:
                break
            self._pending.popleft()
            delivered += 1
        return delivered

    async def aclose(self) -> None:
        """Release the lookup and push clients' connections."""

        await self._sender.aclose()
        await self._lookups.aclose()

    async def _deliver_or_queue(
        self, registration: PushRegistration, notice: ClipReadyNotice
    ) -> None:
        try:
            await self._sender.send(
                token=registration.token,
                platform=registration.platform,
                notice=notice,
            )
            return
        except PushUnavailableError:
            logger.warning(
                "the push provider is unavailable; queued the notice for lookup %s",
                notice.lookup_id,
            )
        self._enqueue(registration, notice)

    def _enqueue(self, registration: PushRegistration, notice: ClipReadyNotice) -> None:
        if len(self._pending) >= self._pending_limit:
            # Bounded so a long outage cannot grow the queue without limit. The
            # oldest notice goes first, matching a queue that drains in order.
            self._pending.popleft()
            logger.warning("the queued-notice limit was reached; the oldest notice was dropped")
        self._pending.append((registration, notice))


def build_default_service(settings: Settings) -> NotificationService:
    """Build the service with its registration store and the lookup and push clients."""

    sender: PushSender
    if settings.push_base_url:
        sender = HttpPushSender(
            base_url=settings.push_base_url,
            timeout_seconds=settings.push_timeout_seconds,
        )
    else:
        sender = LoggingPushSender()
    return NotificationService(
        store=InMemoryRegistrationStore(),
        lookups=HttpLookupDirectory(
            base_url=settings.lookup_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.lookup_timeout_seconds,
        ),
        sender=sender,
        pending_limit=settings.pending_notice_limit,
    )


def _readable_token(token: str) -> bool:
    if not token or len(token) > _MAX_TOKEN_LENGTH:
        return False
    return all(0x21 <= ord(character) <= 0x7E for character in token)
