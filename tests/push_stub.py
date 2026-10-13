"""Test double for the external push provider (C-008 / FEAT-008).

The notification-path QA stack points the notification service's outbound push
send at this double so a clip-ready notice can be observed end to end without
reaching a real push provider. It accepts the same `POST /v1/notifications`
call `HttpPushSender` makes and records every payload; it is test support, never
a shipped service. Two test-only routes under `/test` let a test read and reset
the recorded notices.
"""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI(title="Scenova Push Provider (test double)", version="1.0.0")

_notices: list[dict[str, Any]] = []


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "service": "push-stub"}


@app.post("/v1/notifications", status_code=202)
async def send_notification(request: Request) -> JSONResponse:
    payload = await request.json()
    _notices.append(payload)
    return JSONResponse(status_code=202, content={"accepted": True})


@app.get("/test/notices")
def notices() -> dict[str, list[dict[str, Any]]]:
    """The notices the provider has accepted (test-only)."""

    return {"notices": list(_notices)}


@app.post("/test/reset")
def reset_notices() -> dict[str, int]:
    """Drop every recorded notice (test-only)."""

    _notices.clear()
    return {"notices": 0}
