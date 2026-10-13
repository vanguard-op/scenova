"""Client API tests for the intake (C-007 status, code, and shape mapping)."""

from __future__ import annotations

from analytics.tests.fakes import AUTH, event, make_client

# One valid event per taxonomy name, so the intake is proven to accept the whole
# taxonomy rather than a sample of it.
_TAXONOMY: dict[str, dict[str, object]] = {
    "app_opened": {"source": "launch"},
    "onboarding_completed": {"action_enabled": True, "consent": True},
    "action_enabled": {},
    "consent_changed": {"consent": True},
    "lookup_started": {"kind": "word", "source": "typed"},
    "lookup_served": {"entry_id": "le_1"},
    "generation_started": {"kind": "word", "model_version": "gemini-omni-1.1-flash"},
    "generation_completed": {
        "model_version": "gemini-omni-1.1-flash",
        "duration_ms": 1200,
        "cost_units": 1.0,
        "resolution": "360p",
    },
    "generation_failed": {"reason": "provider_timeout", "model_version": "gemini-omni-1.1-flash"},
    "clip_played": {"entry_id": "le_1", "clip_source": "library"},
    "clip_feedback_given": {"rating": "helpful", "clip_source": "library"},
    "clip_reported": {"reason": "inaccurate", "clip_source": "library"},
    "history_viewed": {"item_count": 3},
    "history_replayed": {"entry_id": "le_1"},
    "history_entry_removed": {"entry_id": "le_1"},
    "preference_changed": {"setting": "sound", "value": "on"},
    "allowance_exhausted": {"plan": "free"},
    "paywall_viewed": {"plan": "free", "lookups_used": 30},
    "purchase_started": {"product_id": "com.scenova.pro.monthly", "product_kind": "subscription"},
    "purchase_completed": {
        "product_id": "com.scenova.pro.monthly",
        "product_kind": "subscription",
    },
    "purchase_failed": {"product_id": "com.scenova.pro.monthly", "reason": "payment_declined"},
}


def test_healthz() -> None:
    with make_client() as client:
        response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json()["service"] == "analytics"


def test_every_taxonomy_event_is_accepted() -> None:
    events = [
        event(eventId=f"evt-{index}", name=name, properties=properties)
        for index, (name, properties) in enumerate(_TAXONOMY.items())
    ]
    with make_client() as client:
        response = client.post("/v1/events", headers=AUTH, json={"events": events})
    assert response.status_code == 202
    assert response.json() == {"accepted": len(_TAXONOMY)}


def test_an_empty_batch_is_accepted() -> None:
    with make_client() as client:
        response = client.post("/v1/events", headers=AUTH, json={"events": []})
    assert response.status_code == 202
    assert response.json() == {"accepted": 0}


def test_a_missing_token_is_unauthorized() -> None:
    with make_client() as client:
        response = client.post("/v1/events", json={"events": [event()]})
    assert response.status_code == 401
    assert response.json()["code"] == "unauthorized"


def test_an_invalid_token_is_unauthorized() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events",
            headers={"Authorization": "Bearer not-a-token"},
            json={"events": [event()]},
        )
    assert response.status_code == 401


def test_a_flood_is_rate_limited() -> None:
    with make_client(rate_limit=1) as client:
        first = client.post("/v1/events", headers=AUTH, json={"events": [event()]})
        second = client.post("/v1/events", headers=AUTH, json={"events": [event(eventId="evt-2")]})
    assert first.status_code == 202
    assert second.status_code == 429
    assert second.json()["code"] == "rate_limited"


def test_an_unknown_event_name_is_rejected() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events", headers=AUTH, json={"events": [event(name="heartbeat")]}
        )
    assert response.status_code == 400
    assert response.json()["code"] == "unknown_event"


def test_an_off_taxonomy_property_is_rejected() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events",
            headers=AUTH,
            json={"events": [event(properties={"kind": "word", "email": "reader@example.com"})]},
        )
    assert response.status_code == 400
    assert response.json()["code"] == "personal_data"


def test_a_personal_data_value_is_rejected() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events",
            headers=AUTH,
            json={
                "events": [
                    event(
                        name="clip_reported",
                        properties={"reason": "reader@example.com", "clip_source": "library"},
                    )
                ]
            },
        )
    assert response.status_code == 400
    assert response.json()["code"] == "personal_data"


def test_a_naive_timestamp_is_rejected() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events",
            headers=AUTH,
            json={"events": [event(occurredAt="2026-10-13T12:00:00")]},
        )
    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_malformed_timestamp_is_rejected() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events", headers=AUTH, json={"events": [event(occurredAt="yesterday")]}
        )
    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_a_batch_over_fifty_is_rejected() -> None:
    events = [event(eventId=f"evt-{index}") for index in range(51)]
    with make_client() as client:
        response = client.post("/v1/events", headers=AUTH, json={"events": events})
    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_extra_top_level_field_is_rejected() -> None:
    with make_client() as client:
        response = client.post(
            "/v1/events",
            headers=AUTH,
            json={"events": [event()], "user_id": "reader-1"},
        )
    assert response.status_code == 400
    assert response.json()["code"] == "invalid_request"


def test_an_unknown_platform_is_rejected() -> None:
    with make_client() as client:
        response = client.post("/v1/events", headers=AUTH, json={"events": [event(platform="web")]})
    assert response.status_code == 400


def test_a_duplicate_event_in_a_batch_is_stored_once() -> None:
    with make_client() as client:
        response = client.post("/v1/events", headers=AUTH, json={"events": [event(), event()]})
    assert response.status_code == 202
    assert response.json() == {"accepted": 1}
