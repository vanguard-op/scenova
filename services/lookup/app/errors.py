"""Domain errors for the lookup service.

Each error carries the HTTP status and machine-readable code the internal API
returns, so the gateway can pass them through to the client contract (C-001,
C-002) without reinterpreting them.
"""

from __future__ import annotations


class LookupError(Exception):
    """Base class for a lookup failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "lookup_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class UnauthorizedError(LookupError):
    """The caller is not an internal service."""

    status_code = 401
    code = "unauthorized"


class EmptySelectionError(LookupError):
    """The selection was empty or only whitespace."""

    status_code = 400
    code = "empty_selection"


class PhraseLimitExceededError(LookupError):
    """The selection held more words than the phrase limit allows."""

    status_code = 400
    code = "phrase_limit_exceeded"


class SelectionTooLongError(LookupError):
    """The selection held more characters than the 80-character bound allows."""

    status_code = 400
    code = "selection_too_long"


class ClientLookupIdConflictError(LookupError):
    """The idempotency key was reused with a different selection."""

    status_code = 409
    code = "client_lookup_id_conflict"


class LookupNotFoundError(LookupError):
    """No lookup exists for the id, or it belongs to another caller."""

    status_code = 404
    code = "lookup_not_found"


class LookupUnavailableError(LookupError):
    """The primary database could not be reached, so the lookup was not recorded.

    The client's 503 is retryable: the lookup is served from the same durable
    record on the retry rather than lost (C-001, C-002).
    """

    status_code = 503
    code = "lookup_unavailable"
