"""Registration and clip-ready notice delivery (FEAT-008, FEAT-011, C-008).

`register` binds a device's push token to the lookup the reader is waiting on.
The lookup must be one the reader owns and that can still put a clip in front of
them: a generation that is still running, or a clip already served that the
reader may report, since a report regenerates one for them (FEAT-011). An unknown
lookup is refused as a bad request; a lookup that resolved without a clip — a
fallback, a denial, an empty selection — needs no notice, so `registered` reports
false rather than holding a token for an event that will never come.

`clip_ready` is the internal call the generation pipeline makes when a clip
finishes (architecture "Notification Service": `Gen --> Notify`). It consumes a
lookup's registrations exactly once — the consumption and the dedupe are the
same rows, so a retried ingest never finds a device to notify again — and queues
every notice before the first send, so a push outage or a crash delays delivery
rather than losing it. `drain_pending` retries the queue once the provider is
back and removes each notice the provider accepts, so a delivered notice is not
sent twice. `PushDrainLoop` runs that retry while the service is up, so the
queue is a delay and not a leak.
"""

from __future__ import annotations

import asyncio
import logging
from uuid import uuid4

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
from .store import (
    NoticeQueue,
    PushRegistration,
    QueuedNotice,
    RegistrationStore,
    build_default_store,
)

logger = logging.getLogger(__name__)

# A lookup a notice can still follow. `generating` is the clip being made; a
# `served` word clip is one the reader can report, and a report regenerates a
# clip for the reporting reader that reaches them by the same notice (FEAT-008,
# FEAT-011). A lookup that resolved without a clip has nothing to regenerate.
_NOTICE_POSSIBLE = frozenset({LookupStatus.GENERATING, LookupStatus.SERVED})

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
        queue: NoticeQueue,
        lookups: LookupDirectory,
        sender: PushSender,
    ) -> None:
        self._store = store
        self._queue = queue
        self._lookups = lookups
        self._sender = sender

    async def register(self, request: RegisterRequest, subject: str) -> RegisterResponse:
        """Record a device for a lookup, or report that no notice is coming.

        The lookup is confirmed against its owner before the token is stored. A
        lookup service that cannot be reached yields `registered=false` rather
        than a claim the service cannot honour; a lookup the reader does not own
        is refused.

        A notice can follow a lookup whose clip is still generating, and one
        whose clip is already served: reporting a served clip regenerates one for
        the reporting reader, and it reaches them by the same notice (FEAT-011).
        Only a lookup that resolved without a clip has nothing to send.
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
        if status not in _NOTICE_POSSIBLE:
            # The lookup resolved without a clip (a fallback, a denial, an empty
            # selection), so no clip is being made and none can be reported.
            # There is no later event to notify about.
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

        One notice per registered device. Every notice is queued before the
        first send, so a provider outage, a crash, or a restart delays it rather
        than losing it; the response counts the notices the queue accepted.
        """

        registrations = await self._store.consume(request.lookupId)
        notice = ClipReadyNotice(
            lookup_id=request.lookupId,
            clip_url=request.clip.url,
            duration_seconds=request.clip.durationSeconds,
            resolution=request.clip.resolution,
            has_audio=request.clip.hasAudio,
            job_id=request.jobId,
        )
        queued = _queued_notices(registrations, notice)
        held = await self._queue.enqueue(queued)
        immediate = {q.id: notice for q in held}
        for notice_row in held:
            await self._send_or_leave(notice_row, immediate[notice_row.id])
        return ClipReadyResponse(queued=len(held))

    async def drain_pending(self) -> int:
        """Retry queued notices; stop at the first provider that is still down.

        Returns how many notices reached the provider, so a drain can be
        observed. Each delivered notice is removed from the queue, so a delivered
        notice is not sent twice by the next drain.
        """

        delivered = 0
        for notice in await self._queue.outstanding():
            try:
                await self._sender.send(
                    token=notice.token,
                    platform=notice.platform,
                    notice=self._notice_from_queue(notice),
                )
            except PushUnavailableError:
                break
            await self._queue.mark_delivered([notice.id])
            delivered += 1
        return delivered

    async def aclose(self) -> None:
        """Release the store, the lookup, and push clients' resources."""

        await self._store.aclose()
        await self._queue.aclose()
        await self._sender.aclose()
        await self._lookups.aclose()

    async def _send_or_leave(self, queued: QueuedNotice, sendable: ClipReadyNotice) -> None:
        """Attempt one queued notice; a failed send stays on the queue."""

        try:
            await self._sender.send(token=queued.token, platform=queued.platform, notice=sendable)
        except PushUnavailableError:
            logger.warning(
                "the push provider is unavailable; the notice for lookup %s is queued",
                queued.lookup_id,
            )
            return
        await self._queue.mark_delivered([queued.id])

    def _notice_from_queue(self, notice: QueuedNotice) -> ClipReadyNotice:
        """The sendable notice a queued row resumes as.

        The queued payload is the C-008 notice's data payload — the lookup and
        the clip (schema "PendingNotice") — and a notice rebuilt from it carries
        no finished job, because the queue holds none.
        """

        return ClipReadyNotice(
            lookup_id=notice.lookup_id,
            clip_url=notice.clip_url,
            duration_seconds=notice.duration_seconds,
            resolution=notice.resolution,
            has_audio=notice.has_audio,
        )


def _queued_notices(
    registrations: list[PushRegistration], notice: ClipReadyNotice
) -> list[QueuedNotice]:
    """A queued notice per registered device, each carrying the C-008 payload."""

    return [
        QueuedNotice(
            id=f"pn_{uuid4().hex}",
            lookup_id=registration.lookup_id,
            token=registration.token,
            platform=registration.platform,
            clip_url=notice.clip_url,
            duration_seconds=notice.duration_seconds,
            resolution=notice.resolution,
            has_audio=notice.has_audio,
        )
        for registration in registrations
    ]


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
    """Build the service with its push store, lookup client, and push sender."""

    store, queue = build_default_store(
        settings.database_url, pending_limit=settings.pending_notice_limit
    )
    return NotificationService(
        store=store,
        queue=queue,
        lookups=HttpLookupDirectory(
            base_url=settings.lookup_base_url,
            internal_audience=settings.internal_audience,
            timeout_seconds=settings.lookup_timeout_seconds,
        ),
        sender=build_push_sender(settings),
    )


class PushDrainLoop:
    """Retries queued notices on an interval while the service runs.

    architecture.md "Notification Service": if the push service is down,
    notifications are queued rather than lost. A queued notice only means that
    while something drains it, so this loop retries the queue, oldest first, and
    stops at the first send the provider still will not take. A drain that
    raises never stops the loop, since a queued notice is only delayed, not
    abandoned.
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
