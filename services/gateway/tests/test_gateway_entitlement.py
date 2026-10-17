"""Gateway tests for the entitlement read, the account settings read, the account
update, and the account deletion (C-018, C-020, C-021, C-022).

The gateway authenticates the reader's token before it forwards the call to the
entitlement service and passes the service's status and body back unchanged, so a
401, a 400, or a 503 reaches the client as the service produced it.

On a deletion the gateway also anonymizes the reader's lookups and events behind
the account, so a data-subject deletion reaches the stores rather than only the
account record (nfr.md "Privacy & Compliance"; analytics.md "Analytics Data
Governance").
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.analytics_client import AnalyticsClient
from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier
from gateway.app.config import Settings
from gateway.app.entitlement_client import EntitlementClient
from gateway.app.errors import UpstreamUnavailableError
from gateway.app.feedback_client import FeedbackClient
from gateway.app.lookup_client import LookupClient, UpstreamResponse
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_READER = {"Authorization": "Bearer dev:reader-1"}


class _FakeEntitlementClient:
    """An entitlement client that records the call it was handed."""

    def __init__(
        self,
        *,
        status_code: int = 200,
        body: bytes = b"{}",
        error: Exception | None = None,
    ) -> None:
        self.status_code = status_code
        self.body = body
        self.error = error
        self.last_method: str | None = None
        self.last_path: str | None = None
        self.last_payload: Mapping[str, Any] | None = None
        self.last_body: bytes | None = None
        self.last_authorization: str | None = None

    async def get_entitlement(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "GET"
        self.last_path = "/v1/entitlement"
        self.last_authorization = authorization
        return self._respond()

    async def get_account(self, authorization: str | None, correlation_id: str) -> UpstreamResponse:
        self.last_method = "GET"
        self.last_path = "/v1/account"
        self.last_authorization = authorization
        return self._respond()

    async def update_account(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "PATCH"
        self.last_path = "/v1/account"
        self.last_payload = payload
        self.last_authorization = authorization
        return self._respond()

    async def delete_account(
        self, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "DELETE"
        self.last_path = "/v1/account"
        self.last_authorization = authorization
        return self._respond()

    async def sync_entitlement(
        self, body: bytes, authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        self.last_method = "POST"
        self.last_path = "/internal/entitlements/sync"
        self.last_body = body
        self.last_authorization = authorization
        return self._respond()

    async def aclose(self) -> None:
        return None

    def _respond(self) -> UpstreamResponse:
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )


class _RecordingLookupClient:
    """A lookup client that records the anonymization calls it is handed."""

    def __init__(self, *, error: Exception | None = None, status_code: int = 200) -> None:
        self.error = error
        self.status_code = status_code
        self.anonymized: list[str] = []

    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the lookup create route is not used in these tests")

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the lookup read route is not used in these tests")

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        self.anonymized.append(subject)
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=b'{"anonymized":1}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


class _RecordingAnalyticsClient:
    """An analytics client that records the anonymization calls it is handed."""

    def __init__(self, *, error: Exception | None = None, status_code: int = 200) -> None:
        self.error = error
        self.status_code = status_code
        self.anonymized: list[str] = []

    async def ingest(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the event intake is not used in these tests")

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        self.anonymized.append(subject)
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=b'{"anonymized":1}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


class _RecordingFeedbackClient:
    """A feedback client that records the anonymization calls it is handed."""

    def __init__(self, *, error: Exception | None = None, status_code: int = 200) -> None:
        self.error = error
        self.status_code = status_code
        self.anonymized: list[str] = []

    async def record_feedback(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the rating intake is not used in these tests")

    async def record_report(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the report intake is not used in these tests")

    async def review(
        self,
        method: str,
        path: str,
        *,
        params: Mapping[str, str] | None,
        body: bytes | None,
        authorization: str | None,
        correlation_id: str,
    ) -> UpstreamResponse:
        raise AssertionError("the review routes are not used in these tests")

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        self.anonymized.append(subject)
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=b'{"anonymized":1}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


def _client(
    entitlement: EntitlementClient,
    *,
    lookup: LookupClient | None = None,
    analytics: AnalyticsClient | None = None,
    feedback: FeedbackClient | None = None,
) -> TestClient:
    return TestClient(
        create_app(
            settings=Settings(),
            verifier=DevTokenVerifier(),
            limiter=InMemoryFixedWindowRateLimiter(limit=120, window_seconds=60, clock=lambda: 0.0),
            entitlement_client=entitlement,
            lookup_client=lookup or _RecordingLookupClient(),
            analytics_client=analytics or _RecordingAnalyticsClient(),
            feedback_client=feedback or _RecordingFeedbackClient(),
        )
    )


def test_the_entitlement_read_passes_through_with_the_reader_token() -> None:
    entitlement = _FakeEntitlementClient(
        body=b'{"plan":"free","lookupsUsed":3,"lookupsLimit":20,"periodStart":"a",'
        b'"periodEnd":"b","status":"active","trialEndsAt":null}'
    )

    with _client(entitlement) as client:
        response = client.get("/v1/entitlement", headers={**_READER, "x-correlation-id": "corr-1"})

    assert response.status_code == 200
    assert response.json()["lookupsUsed"] == 3
    assert response.headers["x-correlation-id"] == "corr-1"
    assert entitlement.last_method == "GET"
    assert entitlement.last_path == "/v1/entitlement"
    assert entitlement.last_authorization == _READER["Authorization"]


def test_the_account_read_passes_through_with_the_reader_token() -> None:
    entitlement = _FakeEntitlementClient(body=b'{"consentModelProcessing":true,"locale":"en-GB"}')

    with _client(entitlement) as client:
        response = client.get("/v1/account", headers={**_READER, "x-correlation-id": "corr-3"})

    assert response.status_code == 200
    assert response.json() == {"consentModelProcessing": True, "locale": "en-GB"}
    assert response.headers["x-correlation-id"] == "corr-3"
    assert entitlement.last_method == "GET"
    assert entitlement.last_path == "/v1/account"
    assert entitlement.last_authorization == _READER["Authorization"]


def test_the_account_update_passes_through_with_its_body() -> None:
    entitlement = _FakeEntitlementClient(body=b'{"consentModelProcessing":true,"locale":"en"}')

    with _client(entitlement) as client:
        response = client.patch(
            "/v1/account", headers=_READER, json={"consentModelProcessing": True, "locale": "en"}
        )

    assert response.status_code == 200
    assert response.json() == {"consentModelProcessing": True, "locale": "en"}
    assert entitlement.last_method == "PATCH"
    assert entitlement.last_payload == {"consentModelProcessing": True, "locale": "en"}


def test_the_account_deletion_passes_through_with_the_reader_token() -> None:
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"deleted":true}')

    with _client(entitlement) as client:
        response = client.delete("/v1/account", headers={**_READER, "x-correlation-id": "corr-2"})

    assert response.status_code == 202
    assert response.json() == {"deleted": True}
    assert response.headers["x-correlation-id"] == "corr-2"
    assert entitlement.last_method == "DELETE"
    assert entitlement.last_path == "/v1/account"
    assert entitlement.last_authorization == _READER["Authorization"]


def test_a_missing_token_is_unauthorized_before_the_service_is_called() -> None:
    entitlement = _FakeEntitlementClient()

    with _client(entitlement) as client:
        read = client.get("/v1/entitlement")
        account = client.get("/v1/account")
        update = client.patch("/v1/account", json={"locale": "en"})
        delete = client.delete("/v1/account")

    assert read.status_code == 401
    assert account.status_code == 401
    assert update.status_code == 401
    assert delete.status_code == 401
    assert read.json()["code"] == "unauthorized"
    assert entitlement.last_path is None


def test_a_deleted_account_error_passes_through() -> None:
    entitlement = _FakeEntitlementClient(
        status_code=401, body=b'{"code":"no_account","message":"This account no longer exists."}'
    )

    with _client(entitlement) as client:
        response = client.delete("/v1/account", headers=_READER)

    assert response.status_code == 401
    assert response.json()["code"] == "no_account"


def test_a_service_error_passes_through() -> None:
    entitlement = _FakeEntitlementClient(
        status_code=400, body=b'{"code":"unknown_locale","message":"That language is unknown."}'
    )

    with _client(entitlement) as client:
        response = client.patch("/v1/account", headers=_READER, json={"locale": "zz"})

    assert response.status_code == 400
    assert response.json()["code"] == "unknown_locale"


def test_an_unreachable_entitlement_service_is_a_service_unavailable() -> None:
    entitlement = _FakeEntitlementClient(error=UpstreamUnavailableError("down"))

    with _client(entitlement) as client:
        response = client.get("/v1/entitlement", headers=_READER)

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"


def test_deletion_anonymizes_the_readers_lookups_events_ratings_and_reports() -> None:
    # A deletion reaches the reader's data across the services, not only the
    # account store: their lookups, their events, and their ratings and reports
    # are anonymized behind the account (nfr.md "Privacy & Compliance";
    # analytics.md "Analytics Data Governance").
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"deleted":true}')
    lookup = _RecordingLookupClient()
    analytics = _RecordingAnalyticsClient()
    feedback = _RecordingFeedbackClient()

    with _client(entitlement, lookup=lookup, analytics=analytics, feedback=feedback) as client:
        response = client.delete("/v1/account", headers=_READER)

    assert response.status_code == 202
    assert response.json() == {"deleted": True}
    assert lookup.anonymized == ["reader-1"]
    assert analytics.anonymized == ["reader-1"]
    assert feedback.anonymized == ["reader-1"]


def test_a_refused_deletion_anonymizes_nothing() -> None:
    entitlement = _FakeEntitlementClient(
        status_code=401, body=b'{"code":"no_account","message":"This account no longer exists."}'
    )
    lookup = _RecordingLookupClient()
    analytics = _RecordingAnalyticsClient()
    feedback = _RecordingFeedbackClient()

    with _client(entitlement, lookup=lookup, analytics=analytics, feedback=feedback) as client:
        response = client.delete("/v1/account", headers=_READER)

    assert response.status_code == 401
    assert lookup.anonymized == []
    assert analytics.anonymized == []
    assert feedback.anonymized == []


def test_an_unreachable_store_does_not_fail_the_deletion() -> None:
    # The account is already gone when the erasure runs, so a store that cannot
    # be reached is left for the data-subject-request runbook to re-run rather
    # than failing a deletion the reader has completed.
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"deleted":true}')
    lookup = _RecordingLookupClient(error=UpstreamUnavailableError("down"))
    analytics = _RecordingAnalyticsClient()
    feedback = _RecordingFeedbackClient()

    with _client(entitlement, lookup=lookup, analytics=analytics, feedback=feedback) as client:
        response = client.delete("/v1/account", headers=_READER)

    assert response.status_code == 202
    assert response.json() == {"deleted": True}
    # The other stores are still anonymized.
    assert analytics.anonymized == ["reader-1"]
    assert feedback.anonymized == ["reader-1"]


def test_a_store_that_refuses_the_erasure_does_not_fail_the_deletion() -> None:
    # A non-2xx from a seam is a refused erasure, not a failed deletion: the
    # account is already gone and the reader's request stands.
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"deleted":true}')
    lookup = _RecordingLookupClient()
    analytics = _RecordingAnalyticsClient(status_code=401)
    feedback = _RecordingFeedbackClient()

    with _client(entitlement, lookup=lookup, analytics=analytics, feedback=feedback) as client:
        response = client.delete("/v1/account", headers=_READER)

    assert response.status_code == 202
    assert analytics.anonymized == ["reader-1"]
    assert feedback.anonymized == ["reader-1"]


# --- The store billing sync (C-019) ------------------------------------------


_WEBHOOK = {"Authorization": "processor-secret"}


def test_the_store_billing_sync_is_forwarded_with_the_webhooks_authorization() -> None:
    # The payment processor is not a reader: the gateway forwards the webhook's
    # own Authorization header and the body unread, and the entitlement service's
    # answer reaches the processor as it was produced (C-019).
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"applied":true}')

    with _client(entitlement) as client:
        response = client.post(
            "/internal/entitlements/sync",
            headers={**_WEBHOOK, "x-correlation-id": "corr-9"},
            json={
                "accountId": "reader-1",
                "event": "purchase",
                "store": "app_store",
                "productId": "com.scenova.pro.monthly",
                "productKind": "subscription",
                "amountMinor": 699,
                "currency": "USD",
                "occurredAt": "2026-10-15T12:00:00+00:00",
            },
        )

    assert response.status_code == 202
    assert response.json() == {"applied": True}
    assert response.headers["x-correlation-id"] == "corr-9"
    assert entitlement.last_method == "POST"
    assert entitlement.last_path == "/internal/entitlements/sync"
    assert entitlement.last_authorization == _WEBHOOK["Authorization"]
    # The body is passed through unread, so the entitlement service stays the
    # contract's single validator.
    assert entitlement.last_body is not None
    assert b'"event":"purchase"' in entitlement.last_body


def test_the_store_billing_sync_does_not_require_a_reader_token() -> None:
    # A processor carries no Firebase token; the gateway must not resolve a
    # subject here, or the webhook would be 401'd before it was routed.
    entitlement = _FakeEntitlementClient(status_code=202, body=b'{"applied":true}')

    with _client(entitlement) as client:
        response = client.post(
            "/internal/entitlements/sync",
            headers=_WEBHOOK,
            json={"accountId": "reader-1"},
        )

    assert response.status_code == 202
    assert entitlement.last_path == "/internal/entitlements/sync"


def test_an_unauthenticated_billing_sync_is_refused_by_the_service() -> None:
    # The gateway forwards the call and the entitlement service owns the
    # refusal, so an unauthenticated delivery is 401 as the service produced it,
    # never the gateway's own reader-token refusal.
    entitlement = _FakeEntitlementClient(
        status_code=401,
        body=b'{"code":"unauthorized","message":"This endpoint is for the processor only."}',
    )

    with _client(entitlement) as client:
        response = client.post("/internal/entitlements/sync", json={"accountId": "reader-1"})

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"
    assert entitlement.last_path == "/internal/entitlements/sync"
    assert entitlement.last_authorization is None


def test_a_billing_sync_error_passes_through() -> None:
    # C-019's 400 and 404 reach the processor as the service produced them.
    entitlement = _FakeEntitlementClient(
        status_code=404, body=b'{"code":"account_not_found","message":"No such account."}'
    )

    with _client(entitlement) as client:
        response = client.post(
            "/internal/entitlements/sync", headers=_WEBHOOK, json={"accountId": "nobody"}
        )

    assert response.status_code == 404
    assert response.json()["code"] == "account_not_found"


def test_an_unreachable_entitlement_service_refuses_a_billing_sync() -> None:
    entitlement = _FakeEntitlementClient(error=UpstreamUnavailableError("down"))

    with _client(entitlement) as client:
        response = client.post(
            "/internal/entitlements/sync", headers=_WEBHOOK, json={"accountId": "reader-1"}
        )

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"
