"""Client HTTP API for the analytics event intake (C-007).

`POST /v1/events` authenticates the caller, rate-limits the batch, validates it
against the taxonomy, and stores it. Authentication and rate limiting are also
applied at the gateway in the deployed topology; enforcing them here keeps the
intake correct when it is addressed directly.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier, build_token_verifier
from .config import Settings
from .errors import AnalyticsError, RateLimitedError
from .models import IngestRequest, IngestResponse
from .ratelimit import InMemoryFixedWindowRateLimiter, RateLimiter
from .service import EventService, build_default_service


def create_app(
    settings: Settings | None = None,
    service: EventService | None = None,
    verifier: TokenVerifier | None = None,
    limiter: RateLimiter | None = None,
) -> FastAPI:
    """Build the analytics event intake application."""

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or build_default_service(resolved_settings)
    resolved_verifier = verifier or build_token_verifier(resolved_settings)
    resolved_limiter = limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )

    app = FastAPI(title="Scenova Analytics", version="1.0.0")

    @app.exception_handler(AnalyticsError)
    async def _handle_analytics_error(_request: Request, exc: AnalyticsError) -> JSONResponse:
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
        return {"status": "ok", "service": "analytics"}

    @app.post("/v1/events", status_code=202)
    async def ingest_events(
        payload: IngestRequest,
        request: Request,
        authorization: Annotated[str | None, Header()] = None,
    ) -> IngestResponse:
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_limiter.allow(subject.id):
            raise RateLimitedError("Too many events. Please try again in a moment.")
        return await resolved_service.ingest(payload, subject.id)

    return app


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
