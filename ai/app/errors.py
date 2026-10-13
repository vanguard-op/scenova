"""Domain errors for the model-serving layer.

Each error carries the HTTP status and machine-readable code the internal API
returns, matching the convention the lookup service uses so the pipeline can
map every internal error the same way (C-004, C-005).
"""

from __future__ import annotations


class ModelError(Exception):
    """Base class for a model-serving failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "model_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class UnauthorizedError(ModelError):
    """The caller is not the internal generation pipeline."""

    status_code = 401
    code = "unauthorized"


class TargetDurationExceededError(ModelError):
    """The requested clip duration is over the four-second cap (C-005).

    A malformed target is a request-contract violation, not a provider outcome:
    it is a 400, kept distinct from the 422 the provider's decline returns so the
    pipeline can tell the two apart.
    """

    status_code = 400
    code = "target_duration_exceeded"


class ProviderUnavailableError(ModelError):
    """The model provider could not be reached after retries."""

    status_code = 503
    code = "provider_unavailable"


class ProviderDeclinedError(ModelError):
    """The provider declined the phrase, so no clip was produced (C-005)."""

    status_code = 422
    code = "provider_declined"


class ProviderTimeoutError(ModelError):
    """The provider did not finish the clip inside the timeout (C-005)."""

    status_code = 504
    code = "provider_timeout"


class StorageUnavailableError(ModelError):
    """The generated clip could not be stored, so there is nothing to serve."""

    status_code = 503
    code = "storage_unavailable"


class ClipNotFoundError(ModelError):
    """A requested clip is not on local disk, so there is nothing to serve."""

    status_code = 404
    code = "clip_not_found"
