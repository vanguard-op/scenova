"""Client API tests for the gateway's rating and report routes (C-012, C-013).

The gateway authenticates and rate-limits the intake and forwards the caller's
token to the feedback service, whose ownership, served-clip, and queue checks pass
back through unchanged.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier, Subject, TokenVerifier
from gateway.app.config import Settings
from gateway.app.errors import UpstreamUnavailableError
from gateway.app.feedback_client import FeedbackClient
from gateway.app.lookup_client import LookupClient, UpstreamResponse
from gateway.app.notification_client import PushRegistrationClient
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_AUTH = {"Authorization": "Bearer dev:reader-1"}

_FEEDBACK = {"lookupId": "lk_1", "rating": "helpful", "clientFeedbackId": "cf_1"}
_REPORT = {
    "lookupId": "lk_1",
    "reason": "wrong_meaning",
    "note": None,
    "clientReportId": "cr_1",
}


class _Verifier:
    async def verify(self, authorization: str | None) -> Subject:
        return Subject(id="reader-1")


class _FakeFeedbackClient:
    def __init__(
        self,
        *,
        status_code: int = 202,
        body: bytes = b'{"recorded":true}',
        error: Exception | None = None,
    ) -> None:
        self.status_code = status_code
        self.body = body
        self.error = error
        self.last_path: str | None = None
        self.last_payload: Mapping[str, Any] | None = None
        self.last_authorization: str | None = None

    async def record_feedback(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._record("/v1/feedback", payload, authorization)

    async def record_report(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        return await self._record("/v1/reports", payload, authorization)

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
        raise AssertionError("the anonymization seam is not used in these tests")

    async def _record(
        self, path: str, payload: Mapping[str, Any], authorization: str | None
    ) -> UpstreamResponse:
        self.last_path = path
        self.last_payload = payload
        self.last_authorization = authorization
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


class _FakeLookupClient:
    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=200, body=b'{"lookupId":"lk_1"}', content_type="application/json"
        )

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=200, body=b'{"lookupId":"lk_1"}', content_type="application/json"
        )

    async def anonymize_subject(self, subject: str, correlation_id: str) -> UpstreamResponse:
        return UpstreamResponse(
            status_code=200, body=b'{"anonymized":0}', content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


class _NoopPushClient:
    async def register(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the push client is not used in these tests")

    async def aclose(self) -> None:
        return None


def _client(
    feedback: FeedbackClient,
    *,
    verifier: TokenVerifier | None = None,
    lookup_client: LookupClient | None = None,
    notification_client: PushRegistrationClient | None = None,
    feedback_rate_limit: int = 120,
) -> TestClient:
    app = create_app(
        settings=Settings(),
        verifier=verifier or _Verifier(),
        limiter=InMemoryFixedWindowRateLimiter(limit=120, window_seconds=60, clock=lambda: 0.0),
        lookup_client=lookup_client or _FakeLookupClient(),
        notification_client=notification_client or _NoopPushClient(),
        feedback_client=feedback,
        feedback_limiter=InMemoryFixedWindowRateLimiter(
            limit=feedback_rate_limit, window_seconds=60, clock=lambda: 0.0
        ),
    )
    return TestClient(app)


def test_a_rating_passes_through_with_the_caller_token() -> None:
    feedback = _FakeFeedbackClient()
    with _client(feedback) as client:
        response = client.post(
            "/v1/feedback", json=_FEEDBACK, headers={**_AUTH, "x-correlation-id": "corr-1"}
        )

    assert response.status_code == 202
    assert response.json() == {"recorded": True}
    assert response.headers["x-correlation-id"] == "corr-1"
    assert feedback.last_path == "/v1/feedback"
    assert feedback.last_payload == _FEEDBACK
    assert feedback.last_authorization == _AUTH["Authorization"]


def test_a_report_passes_through_with_the_caller_token() -> None:
    feedback = _FakeFeedbackClient(body=b'{"reportId":"rp_1","status":"queued"}')
    with _client(feedback) as client:
        response = client.post("/v1/reports", json=_REPORT, headers=_AUTH)

    assert response.status_code == 202
    assert response.json() == {"reportId": "rp_1", "status": "queued"}
    assert feedback.last_path == "/v1/reports"
    assert feedback.last_payload == _REPORT


def test_a_missing_token_is_unauthorized() -> None:
    with _client(_FakeFeedbackClient(), verifier=DevTokenVerifier()) as client:
        response = client.post("/v1/feedback", json=_FEEDBACK)

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_unknown_rating_is_a_bad_request() -> None:
    with _client(_FakeFeedbackClient()) as client:
        response = client.post("/v1/feedback", json={**_FEEDBACK, "rating": "great"}, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_note_over_the_bound_is_a_bad_request() -> None:
    with _client(_FakeFeedbackClient()) as client:
        response = client.post("/v1/reports", json={**_REPORT, "note": "x" * 301}, headers=_AUTH)

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_extra_field_is_rejected() -> None:
    with _client(_FakeFeedbackClient()) as client:
        response = client.post(
            "/v1/feedback", json={**_FEEDBACK, "user_id": "someone"}, headers=_AUTH
        )

    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_lookup_passes_through_as_a_not_found() -> None:
    feedback = _FakeFeedbackClient(
        status_code=404, body=b'{"code":"lookup_not_found","message":"No such lookup."}'
    )
    with _client(feedback) as client:
        response = client.post("/v1/feedback", json=_FEEDBACK, headers=_AUTH)

    assert response.status_code == 404
    assert response.json()["code"] == "lookup_not_found"


def test_a_conflict_passes_through() -> None:
    feedback = _FakeFeedbackClient(
        status_code=409, body=b'{"code":"already_reported","message":"Already reported."}'
    )
    with _client(feedback) as client:
        response = client.post("/v1/reports", json=_REPORT, headers=_AUTH)

    assert response.status_code == 409
    assert response.json()["code"] == "already_reported"


def test_an_unavailable_feedback_service_is_a_service_unavailable() -> None:
    feedback = _FakeFeedbackClient(error=UpstreamUnavailableError("down"))
    with _client(feedback) as client:
        response = client.post("/v1/feedback", json=_FEEDBACK, headers=_AUTH)

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"


def test_a_flood_is_rate_limited() -> None:
    with _client(_FakeFeedbackClient(), feedback_rate_limit=1) as client:
        first = client.post("/v1/feedback", json=_FEEDBACK, headers=_AUTH)
        second = client.post(
            "/v1/feedback",
            json={**_FEEDBACK, "clientFeedbackId": "cf_2"},
            headers=_AUTH,
        )

    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"
