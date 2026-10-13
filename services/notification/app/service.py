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
provider is back. `PushDrainLoop` runs that retry while the service is up, so the
queue is a delay and not a leak. Each finished job is claimed once, so a retried
ingest never sends a second notice.
"""

from __future__ import annotations

import asyncio
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
    FcmPushSender,
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


def build_push_sender(settings: Settings) -> PushSender:
    """Build the sender for the configured push provider.

    Firebase Cloud Messaging is the platform's configured provider; a send
    through it is authorized from Application Default Credentials, so no
    credential is carried in configuration (NFR-024). When the provider is
    Firebase but no send endpoint is declared, or when a generic endpoint is
    configured instead (the seam a test double stands behind), that endpoint is
    used. With nothing configured the logging seam stands in, so the service
    still boots and the delivery is observable.
    """

    if settings.push_provider == "firebase" and settings.push_fcm_base_url:
        return FcmPushSender(
            base_url=settings.push_fcm_base_url,
            project_id=settings.firebase_project_id,
            timeout_seconds=settings.push_timeout_seconds,
        )
    if settings.push_base_url:
        return HttpPushSender(
            base_url=settings.push_base_url,
            timeout_seconds=settings.push_timeout_seconds,
        )
    return LoggingPushSender()


def build_default_service(settings: Settings) -> NotificationService:
    """Build the service with its registration store, lookup client, and push sender."""

    return NotificationService(
        store=InMemoryRegistrationStore(),
        lookups=HttpLookupDirectory(
            base_url=settings.lookup_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.lookup_timeout_seconds,
        ),
        sender=build_push_sender(settings),
        pending_limit=settings.pending_notice_limit,
    )


class PushDrainLoop:
    """Retries queued notices on an interval while the service runs.

    architecture.md "Notification Service": if the push service is down,
    notifications are queued rather than lost. The queue only means that while
    something drains it, so this loop retries the queue, oldest first, and stops
    at the first send the provider still will not take. A drain that raises never
    stops the loop, since a queued notice is only delayed, not abandoned.
    """

    def __init__(self, service: NotificationService, *, interval_seconds: float) -> None:
        self._service = service
        self._interval = max(0.1, interval_seconds)

    async def run(self) -> None:
        while True:
            await asyncio.sleep(self._interval)
            try:
                delivered = await self._service.drain_pending()
            except Exception:
                logger.exception("the queued-notice drain failed; it will be retried")
                continue
            if delivered:
                logger.info("delivered %d queued clip-ready notices", delivered)


def _readable_token(token: str) -> bool:
    if not token or len(token) > _MAX_TOKEN_LENGTH:
        return False
    return all(0x21 <= ord(character) <= 0x7E for character in token)
