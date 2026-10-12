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


class ProviderUnavailableError(ModelError):
    """The model provider could not be reached after retries."""

    status_code = 503
    code = "provider_unavailable"
