"""Scenova model-serving service (internal API, C-004, C-005).

Exposes the internal model endpoints the generation pipeline calls. The service
is internal-only: it is not reachable from the client and it never reads page
content, only the word or sense it is given.
"""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from .errors import ModelError
from .routers import clip, clips, phrase


def create_app() -> FastAPI:
    """Build the internal FastAPI application."""

    app = FastAPI(
        title="Scenova Model Serving",
        version="1.0.0",
        # Internal-only surface: no public schema or docs.
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @app.exception_handler(ModelError)
    async def _handle_model_error(_request: Request, exc: ModelError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"code": exc.code, "message": exc.message},
        )

    app.include_router(phrase.router)
    app.include_router(clip.router)
    app.include_router(clips.router)

    # The platform probes /health: Cloud Run's front end answers /healthz with its
    # own 404 before the request reaches the container. /healthz is kept as an
    # alias for the local image smoke test (ci/checks/build.sh).
    @app.get("/health")
    @app.get("/healthz")
    async def health() -> dict[str, str]:
        return {"status": "ok", "service": "model"}

    return app


app = create_app()
