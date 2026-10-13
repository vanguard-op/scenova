"""Serve a stored clip on a local run (FEAT-005, FEAT-006).

A deployment serves clips from object storage behind a CDN. A local run has
neither, so the model service writes the finished clip to disk (the local clip
store) and serves it back here, at the public path a deployment serves from the
CDN, so the reader-facing URL is the same shape either way.

The route is deliberately public and unauthenticated: a shared-library clip is
cache-friendly content that carries no personal data (architecture "Data
Architecture"). Off a local run nothing is on local disk, so the route is a 404
and delivery stays with the CDN.
"""

from __future__ import annotations

import re
from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.responses import FileResponse

from ..clip.store import local_clip_path
from ..config import CLIP_MIME_TYPE, Settings, get_settings
from ..errors import ClipNotFoundError

router = APIRouter(tags=["clips"])

# One path segment, no separators: the clip service names clips `<id>.mp4`, so
# anything else (including a `..` climb or a nested path) is not a clip we made.
_CLIP_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.mp4$")

# Clips are immutable once written, so a client may cache one for a long time.
_CLIP_CACHE_CONTROL = "public, max-age=3600, immutable"


@router.get("/clips/{name}")
async def serve_clip(
    name: str,
    settings: Annotated[Settings, Depends(get_settings)],
) -> FileResponse:
    """Return a locally stored clip, or 404 when this run has none to serve."""

    if settings.clip_store_backend != "local":
        raise ClipNotFoundError("Clips are served by the CDN, not this service.")

    if not _CLIP_NAME.fullmatch(name):
        raise ClipNotFoundError("No clip exists for that name.")

    storage_key = f"{settings.clip_storage_prefix}{name}"
    try:
        path = local_clip_path(settings, storage_key)
    except ValueError as exc:
        raise ClipNotFoundError("No clip exists for that name.") from exc

    if not path.is_file():
        raise ClipNotFoundError("No clip exists for that name.")

    # Starlette's FileResponse answers Range requests, which the players issue
    # when they seek or start playing before the whole clip is read.
    return FileResponse(
        path,
        media_type=CLIP_MIME_TYPE,
        headers={"Cache-Control": _CLIP_CACHE_CONTROL},
    )
