"""Local clip storage and serving (FEAT-005, FEAT-006).

A local run has no object store or CDN, so the clip is written to disk and served
by the model service. These pin the store's write and URL, the backend choice,
and the serving route's contract: the stored bytes come back, a missing or
out-of-root name is a 404, and a range request is served.
"""

from __future__ import annotations

import asyncio
from dataclasses import replace
from pathlib import Path
from typing import Any

import httpx
import pytest
from app.clip.store import (
    GcsClipStore,
    LocalClipStore,
    build_clip_store,
    local_clip_path,
)
from app.config import Settings, get_settings
from app.main import create_app
from helpers import CLIP_BYTES, make_test_settings

LOCAL_BASE = "http://localhost:8090"


def local_settings(tmp_path: Path, **overrides: Any) -> Settings:
    defaults: dict[str, Any] = {
        "clip_store_backend": "local",
        "clip_local_dir": str(tmp_path),
        "clip_local_base_url": LOCAL_BASE,
    }
    defaults.update(overrides)
    return replace(make_test_settings(), **defaults)


def test_the_backend_chooses_the_store() -> None:
    assert isinstance(
        build_clip_store(make_test_settings(clip_store_backend="local")), LocalClipStore
    )
    assert isinstance(build_clip_store(make_test_settings(clip_store_backend="gcs")), GcsClipStore)


@pytest.mark.asyncio
async def test_local_store_writes_the_clip_and_returns_its_url(tmp_path: Path) -> None:
    settings = local_settings(tmp_path)
    store = LocalClipStore(settings)
    key = "clips/abc123.mp4"

    stored = await store.put(storage_key=key, data=CLIP_BYTES, content_type="video/mp4")

    assert stored.storage_key == key
    assert stored.url == f"{LOCAL_BASE}/{key}"


def test_local_store_writes_the_bytes_to_disk(tmp_path: Path) -> None:
    settings = local_settings(tmp_path)
    key = "clips/abc123.mp4"

    asyncio.run(
        LocalClipStore(settings).put(storage_key=key, data=CLIP_BYTES, content_type="video/mp4")
    )

    assert (tmp_path / key).read_bytes() == CLIP_BYTES
    # The staging file is renamed onto the target, never left behind.
    assert list(tmp_path.rglob("*.part")) == []


def test_a_key_that_escapes_the_clip_directory_is_refused(tmp_path: Path) -> None:
    settings = local_settings(tmp_path)

    with pytest.raises(ValueError):
        local_clip_path(settings, "../escaped.mp4")


async def get(
    settings: Settings, path: str, headers: dict[str, str] | None = None
) -> httpx.Response:
    app = create_app()
    app.dependency_overrides[get_settings] = lambda: settings
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://model") as client:
        return await client.get(path, headers=headers)


@pytest.mark.asyncio
async def test_a_stored_clip_is_served_as_video(tmp_path: Path) -> None:
    settings = local_settings(tmp_path)
    key = "clips/abc123.mp4"
    await LocalClipStore(settings).put(storage_key=key, data=CLIP_BYTES, content_type="video/mp4")

    response = await get(settings, "/clips/abc123.mp4")

    assert response.status_code == 200
    assert response.headers["content-type"] == "video/mp4"
    assert response.headers["accept-ranges"] == "bytes"
    assert response.content == CLIP_BYTES


@pytest.mark.asyncio
async def test_a_range_request_is_served_as_a_partial_clip(tmp_path: Path) -> None:
    settings = local_settings(tmp_path)
    key = "clips/abc123.mp4"
    await LocalClipStore(settings).put(storage_key=key, data=CLIP_BYTES, content_type="video/mp4")

    response = await get(settings, "/clips/abc123.mp4", headers={"range": "bytes=0-3"})

    assert response.status_code == 206
    assert response.content == CLIP_BYTES[:4]
    assert response.headers["content-range"] == f"bytes 0-3/{len(CLIP_BYTES)}"


@pytest.mark.asyncio
async def test_a_missing_clip_is_404(tmp_path: Path) -> None:
    response = await get(local_settings(tmp_path), "/clips/absent.mp4")

    assert response.status_code == 404
    assert response.json()["code"] == "clip_not_found"


@pytest.mark.asyncio
async def test_a_name_that_is_not_a_clip_file_is_404(tmp_path: Path) -> None:
    settings = local_settings(tmp_path)
    # A traversal attempt that survives path decoding is still not a clip name.
    response = await get(settings, "/clips/..%2Fescaped.mp4")

    assert response.status_code == 404


@pytest.mark.asyncio
async def test_off_a_local_run_the_route_serves_nothing(tmp_path: Path) -> None:
    settings = local_settings(tmp_path, clip_store_backend="gcs")

    response = await get(settings, "/clips/abc123.mp4")

    assert response.status_code == 404
