"""Domain errors for the account and entitlement service (C-018 to C-020).

Each error carries the HTTP status and machine-readable code the client maps.
`unauthorized` is a missing or invalid token, `no_account` is a valid token with
no account behind it (an anonymous token before sign-in), `invalid_request` is a
body that did not match the contract, `unknown_locale` is a language the product
does not offer, `account_not_found` is a purchase for an account that does not
exist, and `entitlement_unavailable` is a retryable outage the client reconciles
later rather than blocking the reader on (nfr.md "Degradation when a dependency
fails").
"""

from __future__ import annotations


class EntitlementError(Exception):
    """Base class for an entitlement failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "entitlement_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class InvalidRequestError(EntitlementError):
    """The request body did not match the contract."""

    status_code = 400
    code = "invalid_request"


class UnknownLocaleError(EntitlementError):
    """The locale is not one the product offers."""

    status_code = 400
    code = "unknown_locale"


class UnauthorizedError(EntitlementError):
    """The token was missing or invalid, or the caller is not the processor."""

    status_code = 401
    code = "unauthorized"


class NoAccountError(EntitlementError):
    """The token is valid but has no account: the reader has not signed in."""

    status_code = 401
    code = "no_account"


class AccountNotFoundError(EntitlementError):
    """No account exists for the id a purchase names."""

    status_code = 404
    code = "account_not_found"


class EntitlementUnavailableError(EntitlementError):
    """The account or entitlement store could not be reached; the client retries."""

    status_code = 503
    code = "entitlement_unavailable"
