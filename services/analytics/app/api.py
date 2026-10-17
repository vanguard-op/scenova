"""Client HTTP API for the analytics event intake (C-007).

`POST /v1/events` authenticates the caller, rate-limits the batch, validates it
against the taxonomy, and stores it. Authentication and rate limiting are also
applied at the gateway in the deployed topology; enforcing them here keeps the
intake correct when it is addressed directly.

`POST /internal/events/anonymize` anonymizes a deleted reader's events. It is an
internal seam rather than a numbered contract, called when the reader's account
is deleted, and is never reachable from the reader client (analytics.md
"Analytics Data Governance").
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Annotated

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier, build_token_verifier
from .config import Settings
from .errors import AnalyticsError, RateLimitedError, UnauthorizedError
from .models import AnonymizeRequest, AnonymizeResponse, IngestRequest, IngestResponse
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

    # The interactive schema is a development aid; a deployed service does not
    # publish it (nfr.md "Security").
    app = FastAPI(
        title="Scenova Analytics",
        version="1.0.0",
        docs_url="/docs" if resolved_settings.docs_enabled else None,
        redoc_url="/redoc" if resolved_settings.docs_enabled else None,
        openapi_url="/openapi.json" if resolved_settings.docs_enabled else None,
    )

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

    # The platform probes /health: Cloud Run's front end answers /healthz with its
    # own 404 before the request reaches the container. /healthz is kept as an
    # alias for the local image smoke test (ci/checks/build.sh).
    @app.get("/health")
    @app.get("/healthz")
    async def health() -> dict[str, str]:
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

    @app.post("/internal/events/anonymize")
    async def anonymize_events(
        payload: AnonymizeRequest,
        request: Request,
    ) -> AnonymizeResponse:
        _require_internal(resolved_settings, request.headers)
        anonymized = await resolved_service.anonymize_subject(payload.subject)
        return AnonymizeResponse(anonymized=anonymized)

    return app


def _require_internal(settings: Settings, headers: Mapping[str, str]) -> None:
    if not settings.require_internal_auth:
        return
    if headers.get("x-internal-audience") != settings.internal_audience:
        raise UnauthorizedError("This endpoint is for internal callers only.")


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
