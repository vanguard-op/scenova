"""ASGI entrypoint for the generation pipeline (uvicorn target `app.main:app`)."""

from .api import create_app

app = create_app()
