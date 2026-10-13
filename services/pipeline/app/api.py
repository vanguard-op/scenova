"""Internal HTTP API for the generation pipeline (C-003).

Not a client surface: the lookup service enqueues a generation job here on a
library miss, with the internal audience asserted. The endpoint validates the
job, enqueues it once, and returns immediately, so a slow generation never
blocks a lookup.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Annotated
from uuid import uuid4

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .config import Settings
from .errors import PipelineError, UnauthorizedError
from .models import CreateJobRequest, CreateJobResponse, JobStatusResponse
from .service import GenerationService, build_default_service


def create_app(
    settings: Settings | None = None,
    service: GenerationService | None = None,
) -> FastAPI:
    """Build the generation pipeline application."""

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or build_default_service(resolved_settings)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        try:
            yield
        finally:
            await resolved_service.aclose()

    app = FastAPI(title="Scenova Generation Pipeline", version="1.0.0", lifespan=lifespan)

    @app.exception_handler(PipelineError)
    async def _handle_pipeline_error(_request: Request, exc: PipelineError) -> JSONResponse:
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
        return {"status": "ok", "service": "pipeline"}

    @app.post("/internal/generation-jobs", status_code=202)
    async def create_job(
        payload: CreateJobRequest,
        request: Request,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> CreateJobResponse:
        _require_internal(resolved_settings, x_internal_audience)
        correlation_id = request.headers.get(resolved_settings.correlation_id_header) or uuid4().hex
        return await resolved_service.submit(payload, correlation_id)

    @app.get("/internal/generation-jobs/{job_id}")
    async def get_job(
        job_id: str,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> JobStatusResponse:
        _require_internal(resolved_settings, x_internal_audience)
        return await resolved_service.get_status(job_id)

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
