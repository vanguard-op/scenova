"""Client HTTP API for the feedback service (C-012, C-013).

`POST /v1/feedback` records a reader's rating of a clip and `POST /v1/reports`
records a report and holds the entry it is about. Both authenticate the caller,
rate-limit the intake, and scope the work to the token subject. Authentication
and rate limiting are also applied at the gateway in the deployed topology;
enforcing them here keeps the intake correct when it is addressed directly.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier, build_token_verifier
from .config import Settings
from .errors import FeedbackError, RateLimitedError
from .models import FeedbackRequest, FeedbackResponse, ReportRequest, ReportResponse
from .ratelimit import InMemoryFixedWindowRateLimiter, RateLimiter
from .service import FeedbackService, build_default_service


def create_app(
    settings: Settings | None = None,
    service: FeedbackService | None = None,
    verifier: TokenVerifier | None = None,
    limiter: RateLimiter | None = None,
) -> FastAPI:
    """Build the feedback service application."""

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or build_default_service(resolved_settings)
    resolved_verifier = verifier or build_token_verifier(resolved_settings)
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

    return app


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
