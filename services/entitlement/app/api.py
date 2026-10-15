"""HTTP API for the account and entitlement service (C-018 to C-021).

`GET /v1/entitlement` returns a signed-in reader's plan and allowance for the
current period (C-018) and `PATCH /v1/account` stores their consent choice and
locale on the account (C-020). Both authenticate the caller with a Firebase ID
token, so the entitlement is always the token subject's own and a token with no
account is refused. The gateway authenticates the same token first in the
deployed topology; enforcing it here keeps the service correct when it is
addressed directly.

`DELETE /v1/account` removes the reader's account and its entitlement (C-021) and
returns the 202 the client signs out on. The reader's personal data is deleted
within the documented window and the shared library is unchanged.

`POST /internal/entitlements/sync` applies one signed store billing event
(C-019). It takes the payment processor's signed webhook or an internal service
identity, and is never reachable from the reader client.

`POST /internal/entitlements/spend` is the lookup path's check-and-spend. It is
an internal seam rather than a numbered contract: the lookup service calls it
before it serves or generates, so one lookup spends one unit of the allowance
whether it hits the library or generates.

`POST /internal/accounts/purge` runs the retention pass: it hard-deletes every
deleted account past the documented window. It is an internal seam rather than a
numbered contract, triggered by a scheduled caller.
"""

from __future__ import annotations

import hmac
from collections.abc import Mapping
from typing import Annotated

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .auth import Subject, TokenVerifier, build_token_verifier
from .config import Settings
from .errors import EntitlementError, UnauthorizedError
from .models import (
    AccountResponse,
    AccountUpdateRequest,
    DeleteAccountResponse,
    EntitlementResponse,
    EntitlementSyncRequest,
    PurgeResponse,
    SpendRequest,
    SpendResponse,
    SyncResponse,
)
from .service import EntitlementService
from .store import InMemoryEntitlementStore


def create_app(
    settings: Settings | None = None,
    service: EntitlementService | None = None,
    verifier: TokenVerifier | None = None,
) -> FastAPI:
    """Build the account and entitlement application."""

    resolved_settings = settings or Settings.from_env()
    resolved_service = service or EntitlementService(
        store=InMemoryEntitlementStore(),
        free_lookups=resolved_settings.free_lookups,
        pro_lookups=resolved_settings.pro_lookups,
        topup_lookups=resolved_settings.topup_lookups,
        trial_days=resolved_settings.trial_days,
        retention_days=resolved_settings.retention_days,
    )
    resolved_verifier = verifier or build_token_verifier(resolved_settings)

    app = FastAPI(title="Scenova Account & Entitlement Service", version="1.0.0")

    @app.exception_handler(EntitlementError)
    async def _handle_entitlement_error(_request: Request, exc: EntitlementError) -> JSONResponse:
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
        return {"status": "ok", "service": "entitlement"}

    @app.get("/v1/entitlement")
    async def get_entitlement(
        authorization: Annotated[str | None, Header()] = None,
    ) -> EntitlementResponse:
        subject = await resolved_verifier.verify(authorization)
        return await resolved_service.entitlement(subject)

    @app.patch("/v1/account")
    async def update_account(
        payload: AccountUpdateRequest,
        authorization: Annotated[str | None, Header()] = None,
    ) -> AccountResponse:
        subject = await resolved_verifier.verify(authorization)
        return await resolved_service.update_account(subject, payload)

    @app.delete("/v1/account", status_code=202)
    async def delete_account(
        authorization: Annotated[str | None, Header()] = None,
    ) -> DeleteAccountResponse:
        subject = await resolved_verifier.verify(authorization)
        return await resolved_service.delete_account(subject)

    @app.post("/internal/entitlements/sync", status_code=202)
    async def sync_entitlement(
        payload: EntitlementSyncRequest,
        request: Request,
    ) -> SyncResponse:
        _require_processor(resolved_settings, request.headers)
        return await resolved_service.sync(payload)

    @app.post("/internal/entitlements/spend")
    async def spend_allowance(
        payload: SpendRequest,
        request: Request,
    ) -> SpendResponse:
        _require_internal(resolved_settings, request.headers)
        subject = Subject(id=payload.subject)
        return await resolved_service.spend(subject, payload.clientLookupId)

    @app.post("/internal/accounts/purge")
    async def purge_accounts(request: Request) -> PurgeResponse:
        _require_internal(resolved_settings, request.headers)
        purged = await resolved_service.purge_deleted_accounts()
        return PurgeResponse(purged=purged)

    return app


def _require_internal(settings: Settings, headers: Mapping[str, str]) -> None:
    if not settings.require_internal_auth:
        return
    if headers.get("x-internal-audience") != settings.internal_audience:
        raise UnauthorizedError("This endpoint is for internal callers only.")


def _require_processor(settings: Settings, headers: Mapping[str, str]) -> None:
    """Accept the payment processor's signed webhook or an internal service identity.

    The webhook secret is compared in constant time and is never logged
    (NFR-024). An empty secret means the webhook path is not configured, so only
    the internal audience is accepted.
    """

    if not settings.require_internal_auth:
        return
    if headers.get("x-internal-audience") == settings.internal_audience:
        return
    secret = settings.webhook_auth
    presented = headers.get("authorization")
    if secret and presented and hmac.compare_digest(presented, secret):
        return
    raise UnauthorizedError("This endpoint is for the payment processor only.")


def _first_error_message(exc: RequestValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return "The request was malformed."
    first = errors[0]
    location = ".".join(str(part) for part in first.get("loc", ()))
    message = str(first.get("msg", "is invalid"))
    return f"{location}: {message}" if location else message
