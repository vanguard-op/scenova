"""Domain errors for the generation pipeline.

Each error carries the HTTP status and machine-readable code the internal API
returns, matching the convention the lookup and model services use so the caller
can map every failure the same way (C-003).
"""

from __future__ import annotations


class PipelineError(Exception):
    """Base class for a pipeline failure that maps to an HTTP response."""

    status_code: int = 500
    code: str = "pipeline_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class UnauthorizedError(PipelineError):
    """The caller is not an internal service."""

    status_code = 401
    code = "unauthorized"


class InvalidRequestError(PipelineError):
    """The request body did not match the contract."""

    status_code = 400
    code = "invalid_request"


class MissingPhraseError(PipelineError):
    """The job carried no phrase to generate a clip from."""

    status_code = 400
    code = "missing_phrase"


class TargetDurationError(PipelineError):
    """The requested clip duration is outside the four-second cap."""

    status_code = 400
    code = "target_duration_exceeded"


class JobAlreadyEnqueuedError(PipelineError):
    """A job with this jobId is already enqueued, so it is not run twice."""

    status_code = 409
    code = "job_already_enqueued"


class QueueUnavailableError(PipelineError):
    """The job queue could not accept the job."""

    status_code = 503
    code = "queue_unavailable"
