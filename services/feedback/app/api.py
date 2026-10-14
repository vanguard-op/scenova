"""HTTP API for the feedback service (C-012 to C-016).

`POST /v1/feedback` records a reader's rating of a clip and `POST /v1/reports`
records a report and holds the entry it is about. Both authenticate the caller,
rate-limit the intake, and scope the work to the token subject. Authentication
and rate limiting are also applied at the gateway in the deployed topology;
enforcing them here keeps the intake correct when it is addressed directly.

`GET /internal/review/queue`, `GET /internal/review/entries/{entryId}`, and
`POST /internal/review/entries/{entryId}/actions` are the curator console's
operator surface (FEAT-015). They take an operator's token, require the curator
role and a multi-factor session, and are never reachable from the reader client.
The gateway authenticates the operator session before it forwards the call; the
gate enforces the same rule here so a directly-addressed instance is refused too.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier, build_token_verifier
from .config import Settings
from .errors import FeedbackError, RateLimitedError
from .models import (
    ActionRequest,
    ActionResponse,
    EntryDetailResponse,
    FeedbackRequest,
    FeedbackResponse,
    QueueResponse,
    ReportReason,
    ReportRequest,
    ReportResponse,
    ReviewState,
)
from .operator import OperatorVerifier, build_operator_verifier
from .ratelimit import InMemoryFixedWindowRateLimiter, RateLimiter
from .review import ReviewService, build_default_review_service
from .service import FeedbackService, build_default_service
from .store import FeedbackStore, InMemoryFeedbackStore


def create_app(
    settings: Settings | None = None,
    service: FeedbackService | None = None,
    verifier: TokenVerifier | None = None,
    limiter: RateLimiter | None = None,
    review_service: ReviewService | None = None,
    operator_verifier: OperatorVerifier | None = None,
    store: FeedbackStore | None = None,
) -> FastAPI:
    """Build the feedback service application."""

    resolved_settings = settings or Settings.from_env()
    resolved_store = store if store is not None else InMemoryFeedbackStore()
    resolved_service = service or build_default_service(resolved_settings, store=resolved_store)
    resolved_review = review_service or build_default_review_service(
        resolved_settings, resolved_store
    )
    resolved_verifier = verifier or build_token_verifier(resolved_settings)
    resolved_operator = operator_verifier or build_operator_verifier(resolved_settings)
    resolved_limiter = limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            await resolved_service.aclose()
            await resolved_review.aclose()

    app = FastAPI(title="Scenova Feedback Service", version="1.0.0", lifespan=lifespan)

    @app.exception_handler(FeedbackError)
    async def _handle_feedback_error(_request: Request, exc: FeedbackError) -> JSONResponse:
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
        return {"status": "ok", "service": "feedback"}

    @app.post("/v1/feedback", status_code=202)
    async def record_feedback(
        payload: FeedbackRequest,
        authorization: Annotated[str | None, Header()] = None,
    ) -> FeedbackResponse:
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_limiter.allow(subject.id):
            raise RateLimitedError("Too many ratings. Please try again in a moment.")
        return await resolved_service.record_feedback(payload, subject.id)

    @app.post("/v1/reports", status_code=202)
    async def record_report(
        payload: ReportRequest,
        authorization: Annotated[str | None, Header()] = None,
    ) -> ReportResponse:
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_limiter.allow(subject.id):
            raise RateLimitedError("Too many reports. Please try again in a moment.")
        return await resolved_service.record_report(payload, subject.id)

    @app.get("/internal/review/queue")
    async def review_queue(
        reason: Annotated[ReportReason | None, Query()] = None,
        state: Annotated[ReviewState | None, Query()] = None,
        word: Annotated[str | None, Query()] = None,
        page: Annotated[int, Query(ge=1)] = 1,
        authorization: Annotated[str | None, Header()] = None,
    ) -> QueueResponse:
        await resolved_operator.verify(authorization)
        return await resolved_review.queue(
            reason=None if reason is None else reason.value,
            state=state,
            word=word,
            page=page,
        )

    @app.get("/internal/review/entries/{entry_id}")
    async def review_entry(
        entry_id: str,
        authorization: Annotated[str | None, Header()] = None,
    ) -> EntryDetailResponse:
        await resolved_operator.verify(authorization)
        return await resolved_review.entry(entry_id)

    @app.post("/internal/review/entries/{entry_id}/actions")
    async def review_action(
        entry_id: str,
        payload: ActionRequest,
        authorization: Annotated[str | None, Header()] = None,
    ) -> ActionResponse:
        await resolved_operator.verify(authorization)
        return await resolved_review.act(entry_id, payload)

    return app


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
