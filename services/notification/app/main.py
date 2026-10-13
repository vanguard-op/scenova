"""ASGI entrypoint for the notification service (uvicorn target `app.main:app`)."""

from .api import create_app

app = create_app()
