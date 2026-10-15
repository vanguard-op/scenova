"""ASGI entrypoint for the account and entitlement service (uvicorn `app.main:app`)."""

from .api import create_app

app = create_app()
