"""Object storage for generated word clips (FEAT-005).

A finished clip is written to Cloud Storage and served from the CDN, and the
generation pipeline is handed back the storage key and the reader-facing URL.
Storage is a protocol so the unit layer injects a deterministic fake and only
the live path touches the cloud; a storage failure is normalized to one error
the router can map.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from ..config import Settings


class ClipStorageError(Exception):
    """The clip could not be written to object storage."""


@dataclass(frozen=True, slots=True)
class StoredClip:
    """Where a stored clip lives and the URL a client plays it from."""

    storage_key: str
    url: str


@runtime_checkable
class ClipStore(Protocol):
    """The storage call the clip service depends on (injected for tests)."""

    async def put(self, *, storage_key: str, data: bytes, content_type: str) -> StoredClip: ...


def clip_url(*, storage_key: str, settings: Settings) -> str:
    """Build the reader-facing URL for a stored clip.

    The shared library is public, cache-friendly content that holds no personal
    data, so it is served from the CDN base URL when one is configured and from
    the bucket's public object URL otherwise.
    """

    base = settings.clip_cdn_base_url.rstrip("/")
    if base:
        return f"{base}/{storage_key}"
    return f"https://storage.googleapis.com/{settings.clip_bucket}/{storage_key}"


class GcsClipStore:
    """Writes clips to Cloud Storage, the object store in the architecture."""

    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    async def put(self, *, storage_key: str, data: bytes, content_type: str) -> StoredClip:
        if not self._settings.clip_bucket:
            raise ClipStorageError("clip bucket is not configured")
        try:
            # The storage client is blocking; keep it off the event loop.
            await asyncio.to_thread(self._upload, storage_key, data, content_type)
        except ClipStorageError:
            raise
        except Exception as exc:  # storage clients raise many credential/transport types
            raise ClipStorageError("clip upload failed") from exc
        return StoredClip(
            storage_key=storage_key,
            url=clip_url(storage_key=storage_key, settings=self._settings),
        )

    def _upload(self, storage_key: str, data: bytes, content_type: str) -> None:
        # Imported lazily so importing this module never requires cloud
        # credentials; only an actual upload constructs the client.
        from google.cloud import storage  # type: ignore[import-untyped]

        client = storage.Client()
        bucket = client.bucket(self._settings.clip_bucket)
        bucket.blob(storage_key).upload_from_string(data, content_type=content_type)
