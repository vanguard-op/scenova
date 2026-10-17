"""HTTP API for the notification service (C-008, FEAT-008).

`POST /v1/push-registrations` is the client surface: it authenticates the
caller, rate-limits the intake, and records the device against the lookup it is
waiting on. `POST /internal/clip-ready` is the generation pipeline's call when a
clip finishes; it is internal-only and never reachable from the client.
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
from typing import Annotated

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import TokenVerifier, build_token_verifier
from .config import Settings
from .errors import NotificationError, RateLimitedError, UnauthorizedError
from .models import ClipReadyRequest, ClipReadyResponse, RegisterRequest, RegisterResponse
from .ratelimit import InMemoryFixedWindowRateLimiter, RateLimiter
from .service import NotificationService, PushDrainLoop, build_default_service


def create_app(
    settings: Settings | None = None,
    service: NotificationService | None = None,
    verifier: TokenVerifier | None = None,
    limiter: RateLimiter | None = None,
    *,
    run_drain_loop: bool = True,
) -> FastAPI:
    """Build the notification service application.

    `run_drain_loop` starts the queued-notice retry while the service runs, so a
    provider outage delays a notice rather than losing it. Tests that drive the
    queue directly turn it off.
    """

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or build_default_service(resolved_settings)
    resolved_verifier = verifier or build_token_verifier(resolved_settings)
    resolved_limiter = limiter or InMemoryFixedWindowRateLimiter(
        limit=resolved_settings.rate_limit_per_minute,
        window_seconds=resolved_settings.rate_limit_window_seconds,
    )
    drain_loop = (
        PushDrainLoop(
            resolved_service,
            interval_seconds=resolved_settings.push_drain_interval_seconds,
        )
        if run_drain_loop and resolved_settings.push_drain_interval_seconds > 0
        else None
    )

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        drain_task = (
            asyncio.create_task(drain_loop.run(), name="push-drain") if drain_loop else None
        )
        try:
            yield
        finally:
            if drain_task is not None:
                drain_task.cancel()
                with suppress(asyncio.CancelledError):
                    await drain_task
            await resolved_service.aclose()

    # The interactive schema is a development aid; a deployed service does not
    # publish it (nfr.md "Security").
    app = FastAPI(
        title="Scenova Notification Service",
        version="1.0.0",
        lifespan=lifespan,
        docs_url="/docs" if resolved_settings.docs_enabled else None,
        redoc_url="/redoc" if resolved_settings.docs_enabled else None,
        openapi_url="/openapi.json" if resolved_settings.docs_enabled else None,
    )

    @app.exception_handler(NotificationError)
    async def _handle_notification_error(_request: Request, exc: NotificationError) -> JSONResponse:
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
        return {"status": "ok", "service": "notification"}

    @app.post("/v1/push-registrations", status_code=202)
    async def register(
        payload: RegisterRequest,
        authorization: Annotated[str | None, Header()] = None,
    ) -> RegisterResponse:
        subject = await resolved_verifier.verify(authorization)
        if not await resolved_limiter.allow(subject.id):
            raise RateLimitedError("Too many registrations. Please try again in a moment.")
        return await resolved_service.register(payload, subject.id)

    @app.post("/internal/clip-ready", status_code=202)
    async def clip_ready(
        payload: ClipReadyRequest,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> ClipReadyResponse:
        _require_internal(resolved_settings, x_internal_audience)
        return await resolved_service.clip_ready(payload)

    return app


def _require_internal(settings: Settings, audience: str | None) -> None:
    if not settings.require_internal_auth:
        return
    if audience != settings.internal_audience:
        raise UnauthorizedError("This endpoint is for internal callers only.")


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
