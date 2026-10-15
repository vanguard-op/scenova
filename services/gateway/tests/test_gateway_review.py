"""Gateway tests for the curator review routes (C-014 to C-016).

The gateway authenticates the operator session — curator role and a second
factor — before it forwards the call to the review service, and passes the
service's status and body back unchanged.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from fastapi.testclient import TestClient

from gateway.app.api import create_app
from gateway.app.auth import DevTokenVerifier
from gateway.app.config import Settings
from gateway.app.errors import UpstreamUnavailableError
from gateway.app.feedback_client import FeedbackClient
from gateway.app.lookup_client import UpstreamResponse
from gateway.app.operator import DevOperatorVerifier
from gateway.app.ratelimit import InMemoryFixedWindowRateLimiter

_OPERATOR = {"Authorization": "Bearer dev:curator:mfa:priya"}
_NO_ROLE = {"Authorization": "Bearer dev:priya"}
_NO_MFA = {"Authorization": "Bearer dev:curator:priya"}


class _FakeFeedbackClient:
    """A feedback client that records the review call it was handed."""

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
        self.last_params: Mapping[str, str] | None = None
        self.last_body: bytes | None = None
        self.last_authorization: str | None = None

    async def record_feedback(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the intake routes are not used in these tests")

    async def record_report(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the intake routes are not used in these tests")

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
        self.last_method = method
        self.last_path = path
        self.last_params = params
        self.last_body = body
        self.last_authorization = authorization
        if self.error is not None:
            raise self.error
        return UpstreamResponse(
            status_code=self.status_code, body=self.body, content_type="application/json"
        )

    async def aclose(self) -> None:
        return None


class _NoopLookupClient:
    async def create_lookup(
        self, payload: Mapping[str, Any], correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the lookup routes are not used in these tests")

    async def get_lookup(
        self, lookup_id: str, subject: str, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the lookup routes are not used in these tests")

    async def aclose(self) -> None:
        return None


class _NoopPushClient:
    async def register(
        self, payload: Mapping[str, Any], authorization: str | None, correlation_id: str
    ) -> UpstreamResponse:
        raise AssertionError("the push routes are not used in these tests")

    async def aclose(self) -> None:
        return None


def _client(feedback: FeedbackClient) -> TestClient:
    return TestClient(
        create_app(
            settings=Settings(),
            verifier=DevTokenVerifier(),
            operator_verifier=DevOperatorVerifier(),
            limiter=InMemoryFixedWindowRateLimiter(limit=120, window_seconds=60, clock=lambda: 0.0),
            lookup_client=_NoopLookupClient(),
            notification_client=_NoopPushClient(),
            feedback_client=feedback,
        )
    )


def test_the_queue_passes_through_with_the_operator_token() -> None:
    feedback = _FakeFeedbackClient(body=b'{"items":[],"openCount":0,"page":1,"pageCount":1}')

    with _client(feedback) as client:
        response = client.get(
            "/internal/review/queue",
            headers={**_OPERATOR, "x-correlation-id": "corr-1"},
            params={"reason": "offensive", "page": "2"},
        )

    assert response.status_code == 200
    assert response.json()["openCount"] == 0
    assert response.headers["x-correlation-id"] == "corr-1"
    assert feedback.last_method == "GET"
    assert feedback.last_path == "/internal/review/queue"
    assert feedback.last_params == {"reason": "offensive", "page": "2"}
    assert feedback.last_authorization == _OPERATOR["Authorization"]


def test_an_entry_passes_through() -> None:
    feedback = _FakeFeedbackClient(body=b'{"entry":{"entryId":"le_1"},"state":"queued"}')

    with _client(feedback) as client:
        response = client.get("/internal/review/entries/le_1", headers=_OPERATOR)

    assert response.status_code == 200
    assert feedback.last_method == "GET"
    assert feedback.last_path == "/internal/review/entries/le_1"


def test_an_action_passes_through_with_its_body() -> None:
    feedback = _FakeFeedbackClient(
        body=b'{"actionId":"ma_1","entryId":"le_1","status":"active","state":"actioned"}'
    )
    payload = {
        "action": "choose",
        "chosenClip": "serving",
        "phrase": None,
        "notes": None,
        "expectedState": "queued",
    }

    with _client(feedback) as client:
        response = client.post(
            "/internal/review/entries/le_1/actions", headers=_OPERATOR, json=payload
        )

    assert response.status_code == 200
    assert response.json()["state"] == "actioned"
    assert feedback.last_method == "POST"
    assert feedback.last_path == "/internal/review/entries/le_1/actions"
    assert feedback.last_body is not None
    forwarded = feedback.last_body.replace(b" ", b"")
    assert b'"action":"choose"' in forwarded
    assert b'"chosenClip":"serving"' in forwarded


def test_a_missing_operator_session_is_unauthorized() -> None:
    with _client(_FakeFeedbackClient()) as client:
        response = client.get("/internal/review/queue")

    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_operator_without_the_curator_role_is_forbidden() -> None:
    with _client(_FakeFeedbackClient()) as client:
        response = client.get("/internal/review/queue", headers=_NO_ROLE)

    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"


def test_a_curator_without_a_second_factor_is_forbidden() -> None:
    with _client(_FakeFeedbackClient()) as client:
        response = client.get("/internal/review/queue", headers=_NO_MFA)

    assert response.status_code == 403
    assert response.json()["code"] == "forbidden"


def test_an_unavailable_review_service_is_a_service_unavailable() -> None:
    feedback = _FakeFeedbackClient(error=UpstreamUnavailableError("down"))

    with _client(feedback) as client:
        response = client.get("/internal/review/queue", headers=_OPERATOR)

    assert response.status_code == 503
    assert response.json()["code"] == "upstream_unavailable"


def test_a_review_service_error_passes_through() -> None:
    feedback = _FakeFeedbackClient(
        status_code=409, body=b'{"code":"review_conflict","message":"The entry has moved."}'
    )

    with _client(feedback) as client:
        response = client.post("/internal/review/entries/le_1/actions", headers=_OPERATOR, json={})

    assert response.status_code == 409
    assert response.json()["code"] == "review_conflict"
