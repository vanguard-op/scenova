"""Domain errors for the notification service (C-008).

Each error carries the HTTP status and machine-readable code the client maps:
`invalid_request` and `unreadable_token` and `unknown_lookup` are the three 400
causes the contract names, `unauthorized` is the missing or invalid token, and
`rate_limited` is the gateway's throttle.
"""

from __future__ import annotations


class NotificationError(Exception):
    """Base class for a notification failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "notification_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class InvalidRequestError(NotificationError):
    """The request body did not match the contract."""

    status_code = 400
    code = "invalid_request"


class UnreadableTokenError(NotificationError):
    """The push token was present but is not a usable platform token."""

    status_code = 400
    code = "unreadable_token"


class UnknownLookupError(NotificationError):
    """No lookup exists for the id, or it belongs to another reader."""

    status_code = 400
    code = "unknown_lookup"


class UnauthorizedError(NotificationError):
    """The token was missing or invalid."""

    status_code = 401
    code = "unauthorized"


class RateLimitedError(NotificationError):
    """The caller exceeded the push-registration rate limit."""

    status_code = 429
    code = "rate_limited"
