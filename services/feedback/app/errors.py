"""Domain errors for the feedback service (C-012, C-013).

Each error carries the HTTP status and machine-readable code the client maps.
`invalid_request` is a body that did not match the contract, `no_clip_served` is
a lookup the reader never saw a clip for, `lookup_not_found` is an unknown lookup
or one that belongs to another reader, `unauthorized` is the missing or invalid
token, `rate_limited` is the intake throttle, the two `*_conflict` codes are a
reused idempotency key or a second report of the same entry, and
`feedback_store_unavailable` is a retryable outage.
"""

from __future__ import annotations


class FeedbackError(Exception):
    """Base class for a feedback failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "feedback_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class InvalidRequestError(FeedbackError):
    """The request body did not match the contract."""

    status_code = 400
    code = "invalid_request"


class NoClipServedError(FeedbackError):
    """The lookup never served a clip, so there is nothing to rate or report."""

    status_code = 400
    code = "no_clip_served"


class UnauthorizedError(FeedbackError):
    """The token was missing or invalid."""

    status_code = 401
    code = "unauthorized"


class LookupNotFoundError(FeedbackError):
    """No lookup exists for the id, or it belongs to another reader."""

    status_code = 404
    code = "lookup_not_found"


class ClientFeedbackIdConflictError(FeedbackError):
    """The idempotency key was reused with a different rating."""

    status_code = 409
    code = "client_feedback_id_conflict"


class ClientReportIdConflictError(FeedbackError):
    """The idempotency key was reused with a different report."""

    status_code = 409
    code = "client_report_id_conflict"


class AlreadyReportedError(FeedbackError):
    """The same reader has already reported this entry."""

    status_code = 409
    code = "already_reported"


class RateLimitedError(FeedbackError):
    """The caller exceeded the feedback intake's rate limit."""

    status_code = 429
    code = "rate_limited"


class FeedbackStoreUnavailableError(FeedbackError):
    """The feedback could not be held against the library; the client retries."""

    status_code = 503
    code = "feedback_store_unavailable"
