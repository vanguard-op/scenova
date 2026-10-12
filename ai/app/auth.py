"""Internal service-to-service authentication (C-004, C-005).

The model endpoints are reachable only by the generation pipeline, never by the
client. The pipeline asserts the shared internal audience on the
`x-internal-audience` header, the same mechanism the gateway uses to call the
lookup service (C-003), so one convention covers every internal hop.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Header

from .config import Settings, get_settings
from .errors import UnauthorizedError


def require_internal_caller(
    settings: Annotated[Settings, Depends(get_settings)],
    x_internal_audience: Annotated[str | None, Header()] = None,
) -> None:
    """FastAPI dependency: reject any caller that is not the internal pipeline."""

    if x_internal_audience != settings.internal_audience:
        raise UnauthorizedError("This endpoint is for internal callers only.")
