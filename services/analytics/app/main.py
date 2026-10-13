"""ASGI entrypoint for the analytics event intake (uvicorn target `app.main:app`)."""

from .api import create_app

app = create_app()
