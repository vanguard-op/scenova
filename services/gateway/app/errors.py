"""Gateway errors that map to client-facing HTTP responses."""

from __future__ import annotations


class GatewayError(Exception):
    """Base class for a gateway failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "gateway_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class InvalidRequestError(GatewayError):
    """The request body did not match the contract."""

    status_code = 400
    code = "invalid_request"


class EmptySelectionError(GatewayError):
    """The selection was empty or only whitespace."""

    status_code = 400
    code = "empty_selection"


class UnauthorizedError(GatewayError):
    """The token was missing or invalid."""

    status_code = 401
    code = "unauthorized"


class RateLimitedError(GatewayError):
    """The caller exceeded the lookup rate limit."""

    status_code = 429
    code = "rate_limited"


class UpstreamUnavailableError(GatewayError):
    """The lookup service could not be reached."""

    status_code = 503
    code = "upstream_unavailable"
