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


class LibraryUnavailableError(LibraryError):
    """The primary database could not be reached or did not accept the write.

    The internal contracts answer 503 and the caller retries; the lookup falls
    back to generation rather than failing the reader (C-009 to C-011, C-017;
    FEAT-006 edge).
    """

    status_code = 503
    code = "library_unavailable"
