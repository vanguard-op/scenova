"""ASGI entrypoint for the shared word-clip library (uvicorn target `app.main:app`)."""

from .api import create_app

app = create_app()
