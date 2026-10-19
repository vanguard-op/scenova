"""Store-backed acceptance for the curator's read of a legacy rating (C-015, FEAT-010).

A rating recorded before the writable set narrowed to `helpful` and `not_helpful`
still reads exactly as the reader gave it: the curator's review detail (C-015)
reports a stored `wrong` beside the entry's other evidence. The reader's
judgement — not the set the intake now accepts — is what the curator must see, so
the read is the half of the narrowing that would silently regress without a check.

That read can only be exercised where a stored rating survives. The in-memory
stores the wire suites boot are per-process and hold no pre-revision row, so this
check runs the same through-the-wire path against the primary database — the
shipped store — seeds the one legacy row the revision left behind, and reads it
back through the curator's route. It also queues the entry the way the product
does, by reporting the clip, so the store-backed report loop is exercised beside
the read.

Docker (and the compose Postgres it runs) is the primary database locally. When
it cannot be reached the check is skipped rather than silenced — it is this check
that carries the store-backed guarantee, and a skip names that.
"""

from __future__ import annotations

import contextlib
import os
import subprocess
import time
from collections.abc import Generator
from typing import Any
from uuid import uuid4

import httpx2
import pytest

from tests.conftest import (
    FEEDBACK_SERVICE,
    MODEL_STUB,
    REPO_ROOT,
    SERVICES,
    _boot,
)

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

# A database the check forms and then discards, so the developer's own schema is
# never touched and two runs never share rows.
DB_NAME = "scenova_gate_review_store"
DB_URL = f"postgresql+psycopg://scenova:scenova@localhost:5432/{DB_NAME}"

# The review path on the primary database: the client path, the feedback service,
# and the model double, so a word lookup produces the clip whose entry the reader
# reports and whose legacy rating the curator then reads. Ports of their own, so
# this stack never collides with the caller's own boot or the in-memory suites.
REVIEW_PORTS = {
    "gateway": 18880,
    "lookup": 18881,
    "pipeline": 18882,
    "library": 18883,
    "feedback": 18885,
    "model": 18890,
}

# The dev operator verifier accepts `dev:curator:mfa:<subject>` for a curator with
# a second factor (D-011, FEAT-015's operator gate).
OPERATOR = {"Authorization": "Bearer dev:curator:mfa:curator-1"}
# The rating a reader gave before the writable set narrowed, and the moment they
# gave it: `wrong` was written then, and C-015 must still report it.
LEGACY_RATING = "wrong"
LEGACY_CREATED_AT = "2026-09-01T00:00:00+00:00"


def _auth(subject: str = "reader-1") -> dict[str, str]:
    return {"Authorization": f"Bearer dev:{subject}"}


def _compose_postgres() -> bool:
    """Whether the compose Postgres is present and running."""

    listed = subprocess.run(
        ["docker", "compose", "ps", "-q", "postgres"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    if not listed.stdout.strip():
        return False
    state = subprocess.run(
        ["docker", "inspect", "-f", "{{.State.Running}}", *listed.stdout.split()],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return state.stdout.strip() == "true"


def _psql(sql: str, *, db: str = "postgres") -> None:
    subprocess.run(
        [
            "docker",
            "compose",
            "exec",
            "-T",
            "postgres",
            "psql",
            "-U",
            "scenova",
            "-d",
            db,
            "-c",
            sql,
        ],
        cwd=str(REPO_ROOT),
        capture_output=True,
        timeout=60,
        check=True,
    )


def _wait_for_postgres(attempts: int = 60, delay: float = 0.5) -> bool:
    """Wait until the compose Postgres accepts a connection."""

    for _ in range(attempts):
        try:
            _psql("SELECT 1;")
            return True
        except subprocess.CalledProcessError:
            time.sleep(delay)
    return False


@pytest.fixture(scope="module")
def store() -> Generator[str, None, None]:
    """The primary database the check uses: up, migrated, and cleaned after."""

    docker = subprocess.run(["docker", "version"], capture_output=True, timeout=60)
    if docker.returncode != 0:
        pytest.skip(
            "the store-backed check needs docker: the legacy rating lives in the primary database"
        )

    was_running = _compose_postgres()
    started_here = not was_running
    if started_here:
        subprocess.run(
            ["docker", "compose", "up", "-d", "postgres"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            timeout=300,
            check=True,
        )

    def teardown() -> None:
        with contextlib.suppress(subprocess.CalledProcessError):
            _psql(f"DROP DATABASE IF EXISTS {DB_NAME} WITH (FORCE);")
        if started_here:
            subprocess.run(
                ["docker", "compose", "down"],
                cwd=str(REPO_ROOT),
                capture_output=True,
                timeout=120,
            )

    if not _wait_for_postgres():
        teardown()
        pytest.skip("the compose Postgres never accepted a connection")

    try:
        _psql(f"DROP DATABASE IF EXISTS {DB_NAME} WITH (FORCE);")
        _psql(f"CREATE DATABASE {DB_NAME};")
    except subprocess.CalledProcessError as exc:
        teardown()
        pytest.fail(f"the primary database could not be prepared: {exc}")

    migrated = subprocess.run(
        ["bash", str(REPO_ROOT / "ci" / "db.sh"), "migrate"],
        cwd=str(REPO_ROOT),
        env={**os.environ, "DATABASE_URL": DB_URL},
        capture_output=True,
        text=True,
        timeout=600,
    )
    if migrated.returncode != 0:
        teardown()
        pytest.fail(
            f"the migrations would not apply to the check database: {migrated.stderr[-400:]}"
        )

    try:
        yield DB_URL
    finally:
        teardown()


def _serve_word(gateway: httpx2.Client, word: str, *, subject: str = "reader-1") -> dict[str, Any]:
    """Look a word up and wait until a clip is served for it."""

    created = gateway.post(
        "/v1/lookups",
        headers=_auth(subject),
        json={
            "selection": word,
            "clientLookupId": f"id-{uuid4().hex}",
            "platform": "android",
            "locale": "en",
            "consentModelProcessing": True,
        },
    )
    assert created.status_code == 200, created.text
    body: dict[str, Any] = created.json()
    if body["status"] == "generating":
        for _ in range(80):
            response = gateway.get(f"/v1/lookups/{body['lookupId']}", headers=_auth(subject))
            assert response.status_code == 200, response.text
            body = response.json()
            if body["status"] != "generating":
                break
            time.sleep(0.25)
    assert body["status"] == "served", body
    return body


def _served_entry_id(body: dict[str, Any]) -> str:
    served = [sense for sense in body["senses"] if sense.get("clip") and sense.get("entryId")]
    assert served, f"the lookup served no entry: {body}"
    return str(served[0]["entryId"])


def test_a_stored_wrong_rating_still_reaches_the_curator(
    store: str, tmp_path_factory: pytest.TempPathFactory
) -> None:
    """A `wrong` recorded before the revision reads back through C-015."""

    entries = {**SERVICES, "feedback": FEEDBACK_SERVICE, "model": MODEL_STUB}
    word = f"legacysense{uuid4().hex[:8]}"

    with (
        _boot(entries, REVIEW_PORTS, tmp_path_factory, extra_env={"DATABASE_URL": store}) as stack,
        httpx2.Client(base_url=stack.url("gateway"), timeout=10.0) as gateway,
    ):
        body = _serve_word(gateway, word)
        entry_id = _served_entry_id(body)
        lookup_id = body["lookupId"]

        # The entry reaches the curator's queue the way the product queues it:
        # the reader reports the clip and it opens for review (FEAT-011).
        reported = gateway.post(
            "/v1/reports",
            headers=_auth("reader-1"),
            json={
                "lookupId": lookup_id,
                "reason": "wrong_meaning",
                "note": None,
                "clientReportId": f"rp-{uuid4().hex}",
            },
        )
        assert reported.status_code == 202, reported.text

        # The one row the revision left behind: a `wrong` a reader gave before
        # the rating narrowed, written straight to the store because no intake
        # can write it any more.
        _psql(
            "INSERT INTO feedback "
            "(id, lookup_id, subject, client_feedback_id, rating, created_at) "
            f"VALUES ('fb_legacy_wrong', '{lookup_id}', 'reader-legacy', "
            f"'cf-legacy-wrong', '{LEGACY_RATING}', '{LEGACY_CREATED_AT}');",
            db=DB_NAME,
        )

        detail = gateway.get(f"/internal/review/entries/{entry_id}", headers=OPERATOR)

    assert detail.status_code == 200, detail.text
    reviewed: dict[str, Any] = detail.json()
    assert reviewed["entry"]["entryId"] == entry_id
    assert reviewed["state"] == "queued"
    assert reviewed["feedback"] == [
        {"rating": LEGACY_RATING, "createdAt": LEGACY_CREATED_AT}
    ], reviewed["feedback"]
