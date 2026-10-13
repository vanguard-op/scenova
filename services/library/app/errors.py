"""Domain errors for the shared word-clip library.

Each error carries the HTTP status and machine-readable code the internal API
returns, matching the convention the lookup and pipeline services use so an
internal caller can map every failure the same way.
"""

from __future__ import annotations


class LibraryError(Exception):
    """Base class for a library failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "library_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class UnauthorizedError(LibraryError):
    """The caller is not an internal service."""

    status_code = 401
    code = "unauthorized"


class EntryNotFoundError(LibraryError):
    """No entry exists for the id an update addressed."""

    status_code = 404
    code = "entry_not_found"
