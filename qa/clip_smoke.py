"""Live clip smoke: one clip through the shipped word-clip path (C-005, FEAT-005).

The integration harness in `tests/` drives the generation pipeline against a local
model double, and the unit suites pin the clip service and router with a fake
provider. Neither can catch a live integration that no longer works against the
pinned video model — the failure the clip path once shipped with. This smoke
closes that gap: it puts exactly one clip through the shipped C-005 surface — the
real router, the real `ClipService`, the real `GeminiClipModel`, the versioned
prompt artifact — against the pinned model, then checks the response against the
output contract and FEAT-005's success criterion (a clip of three to four
seconds).

Only the object-storage boundary is substituted. The gate environment holds no
Cloud Storage credential, and `ClipStore` is a documented protocol seam, so the
smoke records the clip bytes in memory instead of uploading them; every layer
above the seam is the code that ships.

The returned media is the evidence, not just the served field: `durationSeconds`
is the value the service chose to serve, so the smoke also parses the MP4 for its
real container duration, resolution, and audio track. That is what distinguishes
"the path returned a plausible body" from "the provider made the clip the
contract promises".

Run the live smoke from the repo root (needs the pinned-model credential):

    PYTHONPATH=ai python -m qa.clip_smoke --out qa/reports/NFR-051-smoke.json

Exit codes: 0 the clip met the contract; 2 the run could not be completed (no
credential, no golden set) or the clip broke the contract.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from collections.abc import Iterator, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
_REPO_ROOT = _HERE.parent
_AI_ROOT = _REPO_ROOT / "ai"
if str(_AI_ROOT) not in sys.path:
    sys.path.insert(0, str(_AI_ROOT))

import httpx  # noqa: E402
from app.clip.service import ClipService  # noqa: E402
from app.clip.store import StoredClip, clip_url  # noqa: E402
from app.config import Settings, get_settings, load_settings  # noqa: E402
from app.dependencies import get_clip_service  # noqa: E402
from app.main import create_app  # noqa: E402
from app.prompt import DEFAULT_CLIP_PROMPT_PATH, load_prompt  # noqa: E402
from app.provider import GeminiClipModel  # noqa: E402
from fastapi import FastAPI  # noqa: E402

CLIP_PATH = "/internal/model/clip"
INTERNAL_HEADER = "x-internal-audience"

GOLDEN_FILE = _HERE / "golden" / "word_clip.jsonl"
REPORT_PATH = _HERE / "reports" / "NFR-051-smoke.json"

# The C-005 response is exactly these fields (CONTRACTS.md). Checked as a set so
# a dropped or renamed field is a smoke failure, not a silent drift.
CONTRACT_FIELDS = frozenset(
    {"clipId", "storageKey", "url", "durationSeconds", "resolution", "hasAudio", "synthIdWatermark"}
)

# The product pins the clip's output at 360p with an audio track (FEAT-005;
# architecture "Model Version & Fallback"). The pinned model always watermarks
# generated video with SynthID.
EXPECTED_RESOLUTION = "360p"
EXPECTED_WIDTH = 640
EXPECTED_HEIGHT = 360

# A container's duration is quantized to its frame grid, so the encoded clip can
# trail the requested length by up to one frame; the contract field is exact, the
# media check allows a frame of encoder rounding.
FRAME_TOLERANCE_SECONDS = 0.05


@dataclass(frozen=True, slots=True)
class MediaInfo:
    """What the returned MP4 actually is."""

    brand: str
    container_duration_seconds: float | None
    width: int | None
    height: int | None
    has_video_track: bool
    has_audio_track: bool


_NO_MEDIA = MediaInfo(
    brand="",
    container_duration_seconds=None,
    width=None,
    height=None,
    has_video_track=False,
    has_audio_track=False,
)


def _boxes(data: bytes, start: int, end: int) -> Iterator[tuple[str, int, int]]:
    """Yield (type, payload_start, payload_end) for the ISO-BMFF boxes in a range."""

    offset = start
    while offset + 8 <= end:
        size = int.from_bytes(data[offset : offset + 4], "big")
        box_type = data[offset + 4 : offset + 8].decode("latin-1", "replace")
        header = 8
        if size == 1:
            size = int.from_bytes(data[offset + 8 : offset + 16], "big")
            header = 16
        elif size == 0:
            size = end - offset
        if size < header or offset + size > end:
            break
        yield box_type, offset + header, offset + size
        offset += size


def _mvhd_duration_seconds(data: bytes, start: int, end: int) -> float | None:
    version = data[start]
    if version == 1:
        timescale = int.from_bytes(data[start + 20 : start + 24], "big")
        duration = int.from_bytes(data[start + 24 : start + 32], "big")
    else:
        timescale = int.from_bytes(data[start + 12 : start + 16], "big")
        duration = int.from_bytes(data[start + 16 : start + 20], "big")
    return duration / timescale if timescale else None


def _trak(data: bytes, start: int, end: int) -> tuple[str, int | None, int | None]:
    """Return one track's handler type and its coded width/height (16.16 fixed)."""

    handler = ""
    width: int | None = None
    height: int | None = None
    for box_type, payload_start, payload_end in _boxes(data, start, end):
        if box_type == "tkhd":
            width = int.from_bytes(data[payload_end - 8 : payload_end - 4], "big") // 65536
            height = int.from_bytes(data[payload_end - 4 : payload_end], "big") // 65536
        elif box_type == "mdia":
            for inner, inner_start, _inner_end in _boxes(data, payload_start, payload_end):
                if inner == "hdlr":
                    handler = data[inner_start + 8 : inner_start + 12].decode("latin-1", "replace")
    return handler, width, height


def measure_mp4(data: bytes) -> MediaInfo:
    """Parse the container duration, resolution, and tracks out of an MP4."""

    if len(data) < 12 or data[4:8] != b"ftyp":
        raise ValueError("not an MP4: the ftyp box is missing")
    brand = data[8:12].decode("latin-1", "replace")
    duration: float | None = None
    width: int | None = None
    height: int | None = None
    has_video = False
    has_audio = False
    for box_type, payload_start, payload_end in _boxes(data, 0, len(data)):
        if box_type != "moov":
            continue
        for inner, inner_start, inner_end in _boxes(data, payload_start, payload_end):
            if inner == "mvhd":
                duration = _mvhd_duration_seconds(data, inner_start, inner_end)
            elif inner == "trak":
                handler, track_width, track_height = _trak(data, inner_start, inner_end)
                if handler == "vide":
                    has_video = True
                    width, height = track_width, track_height
                elif handler == "soun":
                    has_audio = True
    return MediaInfo(
        brand=brand,
        container_duration_seconds=duration,
        width=width,
        height=height,
        has_video_track=has_video,
        has_audio_track=has_audio,
    )


class RecordingClipStore:
    """Records the stored clip in memory in place of the object-storage upload.

    The storage boundary is a documented protocol (`ClipStore`); substituting it
    keeps the smoke runnable without a Cloud Storage credential while leaving the
    request contract, the internal-caller auth, the duration clamp, the prompt,
    the provider call, and the response shape as shipped. The recorded bytes are
    the media the smoke measures.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self.writes: list[tuple[str, bytes, str]] = []

    async def put(self, *, storage_key: str, data: bytes, content_type: str) -> StoredClip:
        self.writes.append((storage_key, data, content_type))
        return StoredClip(
            storage_key=storage_key,
            url=clip_url(storage_key=storage_key, settings=self._settings),
        )


@dataclass(frozen=True, slots=True)
class ClipSmoke:
    """One observed clip: the request, the served response, and the media itself."""

    phrase: str
    target_duration_seconds: float
    model_pin: str
    status_code: int
    body: Mapping[str, Any]
    clip_bytes: bytes
    media: MediaInfo
    stored_keys: tuple[str, ...]

    @property
    def reported_duration_seconds(self) -> float | None:
        value = self.body.get("durationSeconds")
        return float(value) if isinstance(value, (int, float)) else None


def build_smoke_app(settings: Settings, store: RecordingClipStore) -> FastAPI:
    """The shipped app, with the live provider and the recording store wired in."""

    service = ClipService(
        model=GeminiClipModel(settings),
        store=store,
        prompt=load_prompt(DEFAULT_CLIP_PROMPT_PATH),
        settings=settings,
    )
    app = create_app()
    app.dependency_overrides[get_clip_service] = lambda: service
    app.dependency_overrides[get_settings] = lambda: settings
    return app


async def _post(
    app: FastAPI, payload: Mapping[str, object], headers: Mapping[str, str]
) -> httpx.Response:
    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://model") as client:
        return await client.post(CLIP_PATH, json=payload, headers=headers)


def post_clip(
    app: FastAPI, payload: Mapping[str, object], headers: Mapping[str, str]
) -> httpx.Response:
    """Send one C-005 request to the shipped app and return the response.

    Exposed for the contract-error checks, which never call the provider and so
    need the request without the clip run around it.
    """

    return asyncio.run(_post(app, payload, headers))


def _json_body(response: httpx.Response) -> dict[str, Any]:
    try:
        body = response.json()
    except json.JSONDecodeError:
        return {}
    return dict(body) if isinstance(body, dict) else {}


def run_clip_smoke(
    phrase: str,
    *,
    target_duration_seconds: float = 4.0,
    settings: Settings | None = None,
) -> ClipSmoke:
    """Put exactly one clip through the shipped C-005 path and return what happened."""

    resolved = settings or load_settings()
    store = RecordingClipStore(resolved)
    app = build_smoke_app(resolved, store)
    payload = {
        "phrase": phrase,
        "targetDurationSeconds": target_duration_seconds,
        "modelPin": resolved.clip_model_pin,
    }
    headers = {INTERNAL_HEADER: resolved.internal_audience}
    response = asyncio.run(_post(app, payload, headers))
    data = store.writes[-1][1] if store.writes else b""
    media = measure_mp4(data) if data else _NO_MEDIA
    return ClipSmoke(
        phrase=phrase,
        target_duration_seconds=target_duration_seconds,
        model_pin=resolved.clip_model_pin,
        status_code=response.status_code,
        body=_json_body(response),
        clip_bytes=data,
        media=media,
        stored_keys=tuple(key for key, _data, _content_type in store.writes),
    )


def contract_failures(smoke: ClipSmoke) -> tuple[str, ...]:
    """Every way the observed clip deviates from C-005 and FEAT-005, as text."""

    failures: list[str] = []
    if smoke.status_code != 201:
        failures.append(
            f"expected the clip endpoint to answer 201, got {smoke.status_code}: {dict(smoke.body)}"
        )
    keys = frozenset(smoke.body)
    if keys != CONTRACT_FIELDS:
        failures.append(
            f"expected the C-005 response fields {sorted(CONTRACT_FIELDS)}, got {sorted(keys)}"
        )

    resolution = smoke.body.get("resolution")
    if resolution != EXPECTED_RESOLUTION:
        failures.append(f"expected resolution {EXPECTED_RESOLUTION!r}, got {resolution!r}")
    if smoke.body.get("synthIdWatermark") is not True:
        failures.append(
            f"expected the provider watermark synthIdWatermark=True, got "
            f"{smoke.body.get('synthIdWatermark')!r}"
        )
    if smoke.body.get("hasAudio") is not True:
        failures.append(
            f"expected the clip to carry audio (hasAudio=True), got {smoke.body.get('hasAudio')!r}"
        )

    reported = smoke.reported_duration_seconds
    if reported is None or not 3.0 <= reported <= 4.0:
        failures.append(f"expected durationSeconds between 3 and 4, got {reported!r}")

    clip_id = smoke.body.get("clipId")
    if not isinstance(clip_id, str) or not clip_id:
        failures.append(f"expected a non-empty clipId, got {clip_id!r}")
    storage_key = smoke.body.get("storageKey")
    if not isinstance(storage_key, str) or not storage_key.endswith(".mp4"):
        failures.append(f"expected an .mp4 storageKey, got {storage_key!r}")
    url = smoke.body.get("url")
    if not isinstance(url, str) or not url:
        failures.append(f"expected a non-empty clip url, got {url!r}")

    if len(smoke.stored_keys) != 1:
        failures.append(
            f"expected exactly one clip written to storage, got {len(smoke.stored_keys)}"
        )
    elif storage_key not in smoke.stored_keys:
        failures.append(
            f"the served storageKey {storage_key!r} is not the one the path stored "
            f"({smoke.stored_keys[0]!r})"
        )

    if not smoke.clip_bytes:
        failures.append("the clip path stored no bytes, so no clip was produced")
        return tuple(failures)

    media = smoke.media
    if not media.has_video_track:
        failures.append("the returned media carries no video track")
    measured = media.container_duration_seconds
    within = (
        measured is not None
        and 3.0 - FRAME_TOLERANCE_SECONDS <= measured <= 4.0 + FRAME_TOLERANCE_SECONDS
    )
    if not within:
        failures.append(
            f"expected the encoded clip to run 3-4 seconds (a frame of tolerance), "
            f"measured {measured!r}"
        )
    if (media.width, media.height) != (EXPECTED_WIDTH, EXPECTED_HEIGHT):
        failures.append(
            f"expected a {EXPECTED_WIDTH}x{EXPECTED_HEIGHT} video track, got "
            f"{media.width}x{media.height}"
        )
    if not media.has_audio_track:
        failures.append("the returned media carries no audio track, but hasAudio is True")
    return tuple(failures)


def default_smoke_item() -> Mapping[str, object]:
    """The first NFR-051 golden-set item, so the smoke uses the evaluation's input shape."""

    if not GOLDEN_FILE.exists():
        raise FileNotFoundError(f"the word-clip golden set is missing: {GOLDEN_FILE}")
    for line in GOLDEN_FILE.read_text(encoding="utf-8").splitlines():
        if line.strip():
            item = json.loads(line)
            if isinstance(item, dict):
                return item
    raise ValueError(f"the word-clip golden set is empty: {GOLDEN_FILE}")


def smoke_report(smoke: ClipSmoke) -> dict[str, object]:
    """The smoke result as a JSON report the release decision can read."""

    failures = contract_failures(smoke)
    return {
        "nfrId": "NFR-051",
        "capability": "Word-clip generation",
        "smoke": True,
        "modelPin": smoke.model_pin,
        "phrase": smoke.phrase,
        "targetDurationSeconds": smoke.target_duration_seconds,
        "statusCode": smoke.status_code,
        "contract": dict(smoke.body),
        "media": {
            "brand": smoke.media.brand,
            "containerDurationSeconds": smoke.media.container_duration_seconds,
            "width": smoke.media.width,
            "height": smoke.media.height,
            "hasVideoTrack": smoke.media.has_video_track,
            "hasAudioTrack": smoke.media.has_audio_track,
            "bytes": len(smoke.clip_bytes),
        },
        "meetsContract": not failures,
        "failures": list(failures),
        "generatedAt": datetime.now(UTC).isoformat(),
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="clip-smoke", description="One clip through C-005.")
    parser.add_argument("--phrase", help="the phrase to clip (default: the first golden item)")
    parser.add_argument("--target", type=float, default=4.0, help="target duration in seconds")
    parser.add_argument("--out", help="write the smoke report here as JSON")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    settings = load_settings()
    if not settings.gemini_api_key:
        print(
            "the live clip smoke needs the pinned-model credential (GEMINI_API_KEY); "
            "it is not set.",
            file=sys.stderr,
        )
        return 2

    if args.phrase:
        phrase = args.phrase
    else:
        try:
            phrase = str(default_smoke_item().get("phrase", ""))
        except (FileNotFoundError, ValueError) as exc:
            print(str(exc), file=sys.stderr)
            return 2
    if not phrase:
        print("no phrase to clip", file=sys.stderr)
        return 2

    smoke = run_clip_smoke(phrase, target_duration_seconds=args.target, settings=settings)
    report = smoke_report(smoke)

    if args.out:
        path = Path(args.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    failures = report["failures"]
    assert isinstance(failures, list)
    verdict = "meets" if not failures else "broke"
    media = report["media"]
    assert isinstance(media, dict)
    print(
        f"NFR-051 smoke · {smoke.model_pin} · {smoke.phrase!r} · "
        f"status {smoke.status_code} · served {smoke.reported_duration_seconds}s · "
        f"media {media['containerDurationSeconds']}s {media['width']}x{media['height']} · "
        f"{verdict} the contract",
        file=sys.stderr,
    )
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
