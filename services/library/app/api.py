"""Internal HTTP API for the shared word-clip library (FEAT-006).

Not a client surface. The lookup service reads an entry for a sense, the
generation pipeline writes a finished word clip, and the content review service
moves an entry's status after a report. All three are internal callers and assert
the internal audience; the gateway never routes here.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .config import Settings
from .errors import LibraryError, UnauthorizedError
from .models import (
    EntryDetail,
    FindEntryResponse,
    GetEntryResponse,
    PartOfSpeech,
    ServedClip,
    ServedEntry,
    StoreEntryRequest,
    StoreEntryResponse,
    UpdateEntryRequest,
    UpdateEntryResponse,
)
from .service import LibraryService
from .store import InMemoryLibraryStore, StoredEntry


def create_app(
    settings: Settings | None = None,
    service: LibraryService | None = None,
) -> FastAPI:
    """Build the shared library application."""

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or LibraryService(store=InMemoryLibraryStore())

    app = FastAPI(title="Scenova Shared Word-Clip Library", version="1.0.0")

    @app.exception_handler(LibraryError)
    async def _handle_library_error(_request: Request, exc: LibraryError) -> JSONResponse:
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
        return {"status": "ok", "service": "library"}

    @app.post("/internal/library/entries", status_code=202)
    async def store_entry(
        payload: StoreEntryRequest,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> StoreEntryResponse:
        _require_internal(resolved_settings, x_internal_audience)
        stored = await resolved_service.store(payload.entry, payload.asset)
        return StoreEntryResponse(entryId=stored.entry.id, status=stored.entry.status)

    @app.get("/internal/library/entries")
    async def find_entry(
        lemma: Annotated[str, Query(min_length=1)],
        sense_label: Annotated[str, Query(alias="senseLabel", min_length=1)],
        part_of_speech: Annotated[PartOfSpeech, Query(alias="partOfSpeech")],
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> FindEntryResponse:
        _require_internal(resolved_settings, x_internal_audience)
        stored = await resolved_service.find(lemma, sense_label, part_of_speech)
        return FindEntryResponse(entry=None if stored is None else _served(stored))

    @app.get("/internal/library/entries/{entry_id}")
    async def get_entry(
        entry_id: str,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> GetEntryResponse:
        _require_internal(resolved_settings, x_internal_audience)
        stored = await resolved_service.get(entry_id)
        return GetEntryResponse(entry=_detail(stored))

    @app.patch("/internal/library/entries/{entry_id}")
    async def update_entry(
        entry_id: str,
        payload: UpdateEntryRequest,
        x_internal_audience: Annotated[str | None, Header()] = None,
    ) -> UpdateEntryResponse:
        _require_internal(resolved_settings, x_internal_audience)
        updated = await resolved_service.set_status(entry_id, payload.status)
        return UpdateEntryResponse(entryId=updated.entry.id, status=updated.entry.status)

    return app


def _served(stored: StoredEntry) -> ServedEntry:
    return ServedEntry(
        entryId=stored.entry.id,
        status=stored.entry.status,
        glossPhrase=stored.entry.glossPhrase,
        clip=_clip(stored),
    )


def _detail(stored: StoredEntry) -> EntryDetail:
    return EntryDetail(
        entryId=stored.entry.id,
        lemma=stored.entry.lemma,
        senseLabel=stored.entry.senseLabel,
        partOfSpeech=stored.entry.partOfSpeech,
        glossPhrase=stored.entry.glossPhrase,
        status=stored.entry.status,
        clip=_clip(stored),
    )


def _clip(stored: StoredEntry) -> ServedClip:
    return ServedClip(
        url=stored.asset.url,
        durationSeconds=stored.asset.durationSeconds,
        resolution=stored.asset.resolution,
        hasAudio=stored.asset.hasAudio,
    )


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
