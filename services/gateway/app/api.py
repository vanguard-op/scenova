"""Client HTTP API for the gateway.

Contracts: C-001, C-002, C-007, C-008, C-012, C-013, C-018, C-020, C-021,
C-022.

The gateway authenticates the caller, rate-limits lookups, events, push
registrations, ratings, and reports, validates the request body, and passes the
downstream service's response through unchanged, so the frozen contract's status
codes and error codes reach the client as they are produced. The entitlement
read, the account settings read, the account update, and the account deletion
carry no rate limit of their own; the account screen reads the plan and the saved
choices, writes the consent choice, and deletes the account, none of which is a
flood surface.

An account deletion is the one place the gateway sequences more than one
service: once the entitlement service has removed the account, the gateway
anonymizes the reader's lookups and events behind it (nfr.md "Privacy &
Compliance"; analytics.md "Analytics Data Governance"). The erasure is a
secondary effect, so a store that cannot be reached is logged and left for the
data-subject-request runbook to re-run rather than failing the deletion.

The curator review routes (C-014 to C-016) are operator-only and carried here for
the console: the gateway authenticates the operator session — curator role and
multi-factor — before it forwards the call, and the review service enforces the
same rule behind it. A caller without a session is refused with 401 and an
authenticated caller without the role with 403, at the edge and again upstream.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any
from uuid import uuid4

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .analytics_client import AnalyticsClient, HttpAnalyticsClient
from .auth import Subject, TokenVerifier, build_token_verifier
from .config import Settings
from .entitlement_client import EntitlementClient, HttpEntitlementClient
from .errors import EmptySelectionError, GatewayError, RateLimitedError, UpstreamUnavailableError
from .feedback_client import FeedbackClient, HttpFeedbackClient
from .lookup_client import HttpLookupClient, LookupClient, UpstreamResponse
from .models import (
    AccountUpdateRequest,
    CreateLookupRequest,
    FeedbackRequest,
    IngestEventsRequest,
    RegisterPushRequest,
    ReportRequest,
)
from .notification_client import HttpPushRegistrationClient, PushRegistrationClient
from .operator import OperatorVerifier, build_operator_verifier
from .ratelimit import InMemoryFixedWindowRateLimiter, RateLimiter

logger = logging.getLogger(__name__)


def create_app(
    settings: Settings | None = None,
    verifier: TokenVerifier | None = None,
    limiter: RateLimiter | None = None,
    lookup_client: LookupClient | None = None,
    analytics_client: AnalyticsClient | None = None,
    notification_client: PushRegistrationClient | None = None,
    feedback_client: FeedbackClient | None = None,
    entitlement_client: EntitlementClient | None = None,
    event_limiter: RateLimiter | None = None,
    registration_limiter: RateLimiter | None = None,
    feedback_limiter: RateLimiter | None = None,
    operator_verifier: OperatorVerifier | None = None,
) -> FastAPI:
    """Build the API gateway application."""

    resolved_settings = settings or Settings.from_env()
    resolved_verifier = verifier or build_token_verifier(resolved_settings)
    resolved_operator = operator_verifier or build_operator_verifier(resolved_settings)
    resolved_limiter = limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )
    resolved_event_limiter = event_limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.events_rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )
    resolved_registration_limiter = registration_limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.registrations_rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )
    resolved_feedback_limiter = feedback_limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.feedback_rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )
    resolved_client = lookup_client or HttpLookupClient(
        base_url=resolved_settings.lookup_base_url,
        internal_audience=resolved_settings.internal_audience,
        timeout_seconds=resolved_settings.upstream_timeout_seconds,
    )
    resolved_analytics = analytics_client or HttpAnalyticsClient(
        base_url=resolved_settings.analytics_base_url,
        internal_audience=resolved_settings.internal_audience,
        timeout_seconds=resolved_settings.upstream_timeout_seconds,
    )
    resolved_notification = notification_client or HttpPushRegistrationClient(
        base_url=resolved_settings.notification_base_url,
        timeout_seconds=resolved_settings.upstream_timeout_seconds,
    )
    resolved_feedback = feedback_client or HttpFeedbackClient(
        base_url=resolved_settings.feedback_base_url,
        timeout_seconds=resolved_settings.upstream_timeout_seconds,
    )
    resolved_entitlement = entitlement_client or HttpEntitlementClient(
        base_url=resolved_settings.entitlement_base_url,
        timeout_seconds=resolved_settings.upstream_timeout_seconds,
    )

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            await resolved_client.aclose()
            await resolved_analytics.aclose()
            await resolved_notification.aclose()
            await resolved_feedback.aclose()
            await resolved_entitlement.aclose()

    app = FastAPI(title="Scenova API Gateway", version="1.0.0", lifespan=lifespan)

    @app.exception_handler(GatewayError)
    async def _handle_gateway_error(_request: Request, exc: GatewayError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"code": exc.code, "message": exc.message},
        )

    @app.exception_handler(RequestValidationError)
    async def _handle_validation_error(
        _request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        return JSONResponse(
            status_code=400,
            content={"code": "invalid_request", "message": _first_error_message(exc)},
        )

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok", "service": "gateway"}

    @app.post("/v1/lookups")
    async def create_lookup(payload: CreateLookupRequest, request: Request) -> Response:
        subject = await resolved_verifier.verify(request.headers.get("authorization"))
        if not await resolved_limiter.allow(subject.id):
            raise RateLimitedError("Too many lookups. Please try again in a moment.")
        if payload.selection.strip() == "":
            raise EmptySelectionError("The selection was empty.")
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_client.create_lookup(
            _internal_payload(payload, subject), correlation_id
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.get("/v1/lookups/{lookup_id}")
    async def get_lookup(lookup_id: str, request: Request) -> Response:
        subject = await resolved_verifier.verify(request.headers.get("authorization"))
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_client.get_lookup(lookup_id, subject.id, correlation_id)
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.post("/v1/events", status_code=202)
    async def ingest_events(payload: IngestEventsRequest, request: Request) -> Response:
        authorization = request.headers.get("authorization")
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_event_limiter.allow(subject.id):
            raise RateLimitedError("Too many events. Please try again in a moment.")
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_analytics.ingest(
            payload.model_dump(), authorization, correlation_id
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.post("/v1/push-registrations", status_code=202)
    async def register_push(payload: RegisterPushRequest, request: Request) -> Response:
        authorization = request.headers.get("authorization")
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_registration_limiter.allow(subject.id):
            raise RateLimitedError("Too many registrations. Please try again in a moment.")
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_notification.register(
            payload.model_dump(), authorization, correlation_id
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.post("/v1/feedback", status_code=202)
    async def record_feedback(payload: FeedbackRequest, request: Request) -> Response:
        authorization = request.headers.get("authorization")
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_feedback_limiter.allow(subject.id):
            raise RateLimitedError("Too many ratings. Please try again in a moment.")
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_feedback.record_feedback(
            payload.model_dump(), authorization, correlation_id
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.post("/v1/reports", status_code=202)
    async def record_report(payload: ReportRequest, request: Request) -> Response:
        authorization = request.headers.get("authorization")
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_feedback_limiter.allow(subject.id):
            raise RateLimitedError("Too many reports. Please try again in a moment.")
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_feedback.record_report(
            payload.model_dump(), authorization, correlation_id
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.get("/v1/entitlement")
    async def get_entitlement(request: Request) -> Response:
        authorization = request.headers.get("authorization")
        await resolved_verifier.verify(authorization)
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_entitlement.get_entitlement(authorization, correlation_id)
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.get("/v1/account")
    async def get_account(request: Request) -> Response:
        authorization = request.headers.get("authorization")
        await resolved_verifier.verify(authorization)
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_entitlement.get_account(authorization, correlation_id)
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.patch("/v1/account")
    async def update_account(payload: AccountUpdateRequest, request: Request) -> Response:
        authorization = request.headers.get("authorization")
        await resolved_verifier.verify(authorization)
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_entitlement.update_account(
            payload.model_dump(), authorization, correlation_id
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.delete("/v1/account", status_code=202)
    async def delete_account(request: Request) -> Response:
        authorization = request.headers.get("authorization")
        subject = await resolved_verifier.verify(authorization)
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_entitlement.delete_account(authorization, correlation_id)
        if upstream.status_code == 202:
            # The account is gone, so the reader's lookups and events are
            # anonymized behind it (nfr.md "Privacy & Compliance"; analytics.md
            # "Analytics Data Governance"). The erasure is a secondary effect:
            # a store that cannot be reached is logged and left for the
            # data-subject-request runbook to re-run, rather than failing a
            # deletion the reader has already completed.
            await _erase_reader_data(
                resolved_client, resolved_analytics, subject.id, correlation_id
            )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.get("/internal/review/queue")
    async def review_queue(request: Request) -> Response:
        await resolved_operator.verify(request.headers.get("authorization"))
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_feedback.review(
            "GET",
            "/internal/review/queue",
            params=dict(request.query_params),
            body=None,
            authorization=request.headers.get("authorization"),
            correlation_id=correlation_id,
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.get("/internal/review/entries/{entry_id}")
    async def review_entry(entry_id: str, request: Request) -> Response:
        await resolved_operator.verify(request.headers.get("authorization"))
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_feedback.review(
            "GET",
            f"/internal/review/entries/{entry_id}",
            params=None,
            body=None,
            authorization=request.headers.get("authorization"),
            correlation_id=correlation_id,
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    @app.post("/internal/review/entries/{entry_id}/actions")
    async def review_action(entry_id: str, request: Request) -> Response:
        await resolved_operator.verify(request.headers.get("authorization"))
        correlation_id = _correlation_id(resolved_settings, request)
        upstream = await resolved_feedback.review(
            "POST",
            f"/internal/review/entries/{entry_id}/actions",
            params=None,
            body=await request.body(),
            authorization=request.headers.get("authorization"),
            correlation_id=correlation_id,
        )
        return _passthrough(upstream, correlation_id, resolved_settings)

    return app


def _internal_payload(payload: CreateLookupRequest, subject: Subject) -> dict[str, Any]:
    body: dict[str, Any] = payload.model_dump()
    body["subject"] = subject.id
    # The lookup path meters a signed-in reader's allowance; a reader who has not
    # signed in is metered on the device, so the flag travels with the subject
    # the gateway resolved (C-001).
    body["isAnonymous"] = subject.is_anonymous
    return body


async def _erase_reader_data(
    lookup: LookupClient,
    analytics: AnalyticsClient,
    subject: str,
    correlation_id: str,
) -> None:
    """Anonymize a deleted reader's lookups and events (nfr.md "Privacy & Compliance").

    The reader's account is already gone when this runs, so the erasure is a
    secondary effect of the deletion: a store that cannot be reached is logged
    and left for the data-subject-request runbook to re-run — the seams are
    idempotent — rather than failing a deletion the reader has completed.
    """

    for name, anonymize in (
        ("lookup", lookup.anonymize_subject),
        ("analytics", analytics.anonymize_subject),
    ):
        try:
            response = await anonymize(subject, correlation_id)
        except UpstreamUnavailableError as exc:
            logger.warning("the %s store was not anonymized after a deletion: %s", name, exc)
            continue
        if response.status_code // 100 != 2:
            logger.warning(
                "the %s store refused the anonymization after a deletion (status %s)",
                name,
                response.status_code,
            )


def _passthrough(upstream: UpstreamResponse, correlation_id: str, settings: Settings) -> Response:
    return Response(
        content=upstream.body,
        status_code=upstream.status_code,
        media_type=upstream.content_type,
        headers={settings.correlation_id_header: correlation_id},
    )


def _correlation_id(settings: Settings, request: Request) -> str:
    return request.headers.get(settings.correlation_id_header) or uuid4().hex


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
