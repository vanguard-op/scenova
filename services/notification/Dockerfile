# Scenova notification service container.
#
# Architecture: architecture.md "System Components" — the service is one Cloud
# Run container. Release: release.md "Deployment model" — canary for services.
#
# The build context is this service directory, so nothing outside the service is
# copied into the image. The container listens on the Cloud Run default port 8080
# unless PORT overrides it; the per-service ports in `.env` apply to local
# development only. Configuration and secrets arrive as environment variables at
# runtime (NFR-024) — the image bakes in no secret and reads no repository file.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

WORKDIR /app

# Dependencies first, so a code-only change reuses this layer.
COPY requirements.txt ./
# requirements.txt omits `requests`, which app/push.py needs through
# google.auth.transport.requests (the credential refresh the Firebase Cloud
# Messaging send uses). Install it so the container starts. Remove this once the
# service declares it in requirements.txt.
RUN pip install -r requirements.txt "requests==2.34.2"

# The service code (entrypoint `app.main:app`, the uvicorn target every service
# exposes; `make boot` and this image run the same command).
COPY app ./app

# Unprivileged runtime user (NFR-024); the service writes nothing under /app.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
USER appuser

EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
