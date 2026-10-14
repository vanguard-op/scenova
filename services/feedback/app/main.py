"""ASGI entrypoint for the feedback service (uvicorn target `app.main:app`)."""

from .api import create_app

app = create_app()
