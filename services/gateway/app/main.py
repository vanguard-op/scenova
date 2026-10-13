"""ASGI entrypoint for the API gateway (uvicorn target `app.main:app`)."""

from .api import create_app

app = create_app()
