"""Every service withholds its interactive schema outside local development.

Each service builds its own FastAPI app, so the schema wiring is repeated; this
scan holds every copy to the same rule (nfr.md "Security"). The gateway's
reader-facing behavior under a suppressed schema is covered by its own suite.
"""

from __future__ import annotations

from pathlib import Path

import pytest

SERVICES_ROOT = Path(__file__).resolve().parent

SERVICE_NAMES: list[str] = sorted(
    path.name
    for path in SERVICES_ROOT.iterdir()
    if (path / "app" / "api.py").is_file() and (path / "app" / "config.py").is_file()
)


def test_the_scan_covers_the_services() -> None:
    assert SERVICE_NAMES, "no service scanned — the schema scan is checking nothing"


def _app(service: str, *, docs_enabled: bool) -> object:
    api = __import__(f"{service}.app.api", fromlist=["create_app"])
    config = __import__(f"{service}.app.config", fromlist=["Settings"])
    return api.create_app(settings=config.Settings(docs_enabled=docs_enabled))


@pytest.mark.parametrize("service", SERVICE_NAMES)
def test_schema_publishing_follows_the_setting(service: str) -> None:
    deployed = _app(service, docs_enabled=False)
    assert (deployed.docs_url, deployed.redoc_url, deployed.openapi_url) == (None, None, None)

    development = _app(service, docs_enabled=True)
    assert (development.docs_url, development.redoc_url, development.openapi_url) == (
        "/docs",
        "/redoc",
        "/openapi.json",
    )
