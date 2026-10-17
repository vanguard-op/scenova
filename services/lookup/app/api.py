"""Internal HTTP API for the lookup service.

Not a client surface: the gateway owns C-001 and C-002 and calls these internal
routes with the caller's subject already resolved, so authentication and rate
limiting stay at the gateway. The create route returns C-001's body, allowance
included; the read route returns C-002's, which has none.

`POST /internal/lookups/anonymize` anonymizes a deleted reader's lookups. It is
an internal seam rather than a numbered contract, called when the reader's
account is deleted (nfr.md "Privacy & Compliance").
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated
from uuid import uuid4

from fastapi import FastAPI, Header, Request, Response
from fastapi.responses import JSONResponse

from .config import Settings
from .errors import LookupError, UnauthorizedError
from .models import (
    AnonymizeRequest,
    AnonymizeResponse,
    CreateLookupRequest,
    CreateLookupResponse,
    LookupResponse,
)
from .service import LookupService, build_default_service


def create_app(
    settings: Settings | None = None,
    service: LookupService | None = None,
) -> FastAPI:
    """Build the lookup service application."""

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or build_default_service(resolved_settings)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            await resolved_service.aclose()

    app = FastAPI(title="Scenova Lookup Service", version="1.0.0", lifespan=lifespan)

    @app.exception_handler(LookupError)
    async def _handle_lookup_error(_request: Request, exc: LookupError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"code": exc.code, "message": exc.message},
        )

    # The platform probes /health: Cloud Run's front end answers /healthz with its
    # own 404 before the request reaches the container. /healthz is kept as an
    # alias for the local image smoke test (ci/checks/build.sh).
    @app.get("/health")
    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok", "service": "lookup"}

    @app.post("/internal/lookups")
    async def create_lookup(
        payload: CreateLookupRequest,
        request: Request,
        response: Response,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> CreateLookupResponse:
        _require_internal(resolved_settings, x_internal_audience)
        correlation_id = _correlation_id(resolved_settings, request)
        result = await resolved_service.create_lookup(payload, correlation_id)
        response.headers[resolved_settings.correlation_id_header] = correlation_id
        return result

    @app.post("/internal/lookups/anonymize")
    async def anonymize_lookups(
        payload: AnonymizeRequest,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> AnonymizeResponse:
        _require_internal(resolved_settings, x_internal_audience)
        anonymized = await resolved_service.anonymize_subject(payload.subject)
        return AnonymizeResponse(anonymized=anonymized)

    @app.get("/internal/lookups/{lookup_id}")
    async def get_lookup(
        lookup_id: str,
        subject: str,
        request: Request,
        response: Response,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> LookupResponse:
        _require_internal(resolved_settings, x_internal_audience)
        correlation_id = _correlation_id(resolved_settings, request)
        result = await resolved_service.get_lookup(lookup_id, subject, correlation_id)
        response.headers[resolved_settings.correlation_id_header] = correlation_id
        return result

    return app


def _require_internal(settings: Settings, audience: str | None) -> None:
    if not settings.require_internal_auth:
        return
    if audience != settings.internal_audience:
        raise UnauthorizedError("This endpoint is for internal callers only.")


def _correlation_id(settings: Settings, request: Request) -> str:
    return request.headers.get(settings.correlation_id_header) or uuid4().hex
