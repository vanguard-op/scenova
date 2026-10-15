# Scenova model-serving container (architecture.md "Model Serving / Inference").
#
# The component's code lives in `ai/`, which is the build context. This build
# definition is platform-owned (`infra/docker/`) because the container is a
# platform artifact, not application code; the image it produces is the `model`
# Cloud Run service the deployment topology defines.
#
# The container listens on the Cloud Run default port 8080 unless PORT overrides
# it; the model port in `.env` applies to local development only. The Gemini API
# key arrives from Secret Manager at runtime (NFR-024) — the image bakes in no
# secret and reads no repository file. It is internal-only: reachable only by an
# authenticated service identity (C-004, C-005).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080

WORKDIR /app

# Dependencies first, so a code-only change reuses this layer.
COPY requirements.txt ./
RUN pip install -r requirements.txt

# The service code, the bundled common-word vocabulary under app/data, and the
# versioned prompt artifacts the model behaviour is pinned and measured on.
COPY app ./app
COPY prompts ./prompts

# Unprivileged runtime user (NFR-024). In the cloud clips are written to Cloud
# Storage; a local run writes to the platform temp directory, which is writable.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin appuser
USER appuser

EXPOSE 8080

CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080}"]
