"""Domain errors for the analytics intake (C-007).

Each error carries the HTTP status and machine-readable code the client maps:
`unknown_event` and `personal_data` are the two 400 causes the contract names,
`unauthorized` is the missing or invalid token, and `rate_limited` is the
gateway's throttle.
"""

from __future__ import annotations


class AnalyticsError(Exception):
    """Base class for an intake failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "analytics_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class InvalidRequestError(AnalyticsError):
    """The request body did not match the contract."""

    status_code = 400
    code = "invalid_request"


class UnknownEventError(AnalyticsError):
    """The batch carried an event name outside the taxonomy."""

    status_code = 400
    code = "unknown_event"


class PersonalDataError(AnalyticsError):
    """An event carried a property that is not taxonomy-bounded, or personal data."""

    status_code = 400
    code = "personal_data"


class UnauthorizedError(AnalyticsError):
    """The token was missing or invalid."""

    status_code = 401
    code = "unauthorized"


class RateLimitedError(AnalyticsError):
    """The caller exceeded the event-intake rate limit."""

    status_code = 429
    code = "rate_limited"


class EventStoreUnavailableError(AnalyticsError):
    """The event store could not be reached.

    The batch is answered as retryable, never as accepted: the intake writes
    each event to the primary database before it acknowledges it, so an event
    the store cannot take is not accepted (architecture.md "Analytics / Event
    Tracking"). The client re-sends the batch, and the `event_id` key makes the
    retry idempotent (C-007).
    """

    status_code = 503
    code = "store_unavailable"
