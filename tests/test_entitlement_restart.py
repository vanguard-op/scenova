"""The restart-survival check for the account and entitlement store (FEAT-013).

The entitlement runs its arithmetic in process and writes the result to the
primary database (architecture.md "Primary Database") — so a service that
restarts, or is replaced by its next deployment, keeps every account, its
entitlement for the month, the consent choice stored on the account, and the
idempotency ledger that keeps a resent lookup from spending twice. An allowance
that lived only in the process would silently reset every reader on each deploy.

The check boots the shipped service twice against the real primary database —
the compose PostgreSQL the platform migrations shape (`ci/db.sh`, the same
documented `make db-migrate` path) — inside a throwaway database it creates and
drops, so a developer's own schema is untouched. Each boot is the same uvicorn
module the deployed image runs, and the second boot is a fresh process on a
fresh port: whatever reads back state was carried by the database, not by the
first boot's process.

Docker (and the compose Postgres it runs) is the primary database locally. When
it cannot be reached the check is skipped rather than silenced — it is this
check that carries the store-backed guarantee, and a skip names that.
"""

from __future__ import annotations

import contextlib
import os
import subprocess
from collections.abc import Generator
from uuid import uuid4

import httpx2
import pytest

from tests.conftest import (
    ENTITLEMENT_SERVICE,
    INTERNAL_AUDIENCE,
    REPO_ROOT,
    _boot,
)

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

# A database the check forms and then discards, so the developer's own schema is
# never touched and two runs never share rows.
DB_NAME = "scenova_gate_restart"
DB_URL = f"postgresql+psycopg://scenova:scenova@localhost:5432/{DB_NAME}"
# The restarted process is on a port of its own, so the two boots are two
# services, not one client talking to itself.
FIRST_PORTS = {"entitlement": 18770}
RESTART_PORTS = {"entitlement": 18780}


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


def _psql(sql: str) -> None:
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
            "postgres",
            "-c",
            sql,
        ],
        cwd=str(REPO_ROOT),
        capture_output=True,
        timeout=60,
        check=True,
    )


@pytest.fixture(scope="module")
def store() -> Generator[str, None, None]:
    """The primary database the check restores: up, migrated, and cleaned after."""

    docker = subprocess.run(["docker", "version"], capture_output=True, timeout=60)
    if docker.returncode != 0:
        pytest.skip(
            "the restart-survival check needs docker: the primary database is what survives"
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


def test_the_allowance_and_its_ledgers_survive_a_restart(
    store: str, tmp_path_factory: pytest.TempPathFactory
) -> None:
    """One scenario, two boots: what the first writes, the second still serves."""

    subject = f"restart-{uuid4().hex[:12]}"
    spent_key = f"clid-{uuid4().hex}"
    fresh_key = f"clid-{uuid4().hex}"
    auth = {"Authorization": f"Bearer dev:{subject}"}
    internal = {"x-internal-audience": INTERNAL_AUDIENCE}

    # --- First boot: an account, a stored choice, and a meter that has run. ---
    with (
        _boot(
            {"entitlement": ENTITLEMENT_SERVICE},
            FIRST_PORTS,
            tmp_path_factory,
            extra_env={"DATABASE_URL": store, "FLAG_ENABLE_PAID_TIER": "true"},
        ) as first,
        httpx2.Client(base_url=first.url("entitlement"), timeout=10.0) as session,
        httpx2.Client(base_url=first.url("entitlement"), headers=internal, timeout=10.0) as meter,
    ):
        read = session.get("/v1/entitlement", headers=auth)
        assert read.status_code == 200, read.text
        created: dict[str, object] = read.json()
        assert created["plan"] == "trial", created

        chosen = session.patch("/v1/account", headers=auth, json={"consentModelProcessing": True})
        assert chosen.status_code == 200, chosen.text

        spent = meter.post(
            "/internal/entitlements/spend",
            json={"subject": subject, "clientLookupId": spent_key},
        )
        assert spent.status_code == 200, spent.text
        assert spent.json()["lookupsUsed"] == 1, spent.text

        # The state to survive is the account as the first boot leaves it —
        # metered and all — not the pre-spend snapshot taken above.
        prepared = session.get("/v1/entitlement", headers=auth)
        assert prepared.status_code == 200, prepared.text
        prepared_body: dict[str, object] = prepared.json()

    # --- The second boot: a fresh process, a fresh port, the same database. ---
    with (
        _boot(
            {"entitlement": ENTITLEMENT_SERVICE},
            RESTART_PORTS,
            tmp_path_factory,
            extra_env={"DATABASE_URL": store, "FLAG_ENABLE_PAID_TIER": "true"},
        ) as second,
        httpx2.Client(base_url=second.url("entitlement"), timeout=10.0) as session,
        httpx2.Client(base_url=second.url("entitlement"), headers=internal, timeout=10.0) as meter,
    ):
        # The account is where the first boot left it: the trial, the month's
        # usage, and the period it named.
        read = session.get("/v1/entitlement", headers=auth)
        assert read.status_code == 200, read.text
        assert read.json() == prepared_body, (read.text, prepared_body)
        # The choice stored on the account follows the restart too (C-022).
        settings = session.get("/v1/account", headers=auth)
        assert settings.status_code == 200, settings.text
        assert settings.json() == {
            "consentModelProcessing": True,
            "locale": "en",
        }, settings.text

        # The meter carried over: a resend of a lookup the first boot already
        # spent replays the ledger instead of spending a second unit, and a
        # fresh lookup spends one more than it did before.
        replayed = meter.post(
            "/internal/entitlements/spend",
            json={"subject": subject, "clientLookupId": spent_key},
        )
        assert replayed.status_code == 200, replayed.text
        assert replayed.json()["lookupsUsed"] == 1, replayed.text

        fresh = meter.post(
            "/internal/entitlements/spend",
            json={"subject": subject, "clientLookupId": fresh_key},
        )
        assert fresh.status_code == 200, fresh.text
        assert fresh.json()["lookupsUsed"] == 2, fresh.text
