# Cloud SQL migration job image (architecture.md "Data Architecture"; release.md
# "Data migrations").
#
# The primary database has a private-only address, so migrations run from inside
# the VPC: this image is executed as a Cloud Run job, reads DATABASE_URL from
# Secret Manager, applies `alembic upgrade head`, and exits. It carries only the
# migration toolchain and the revisions — no service code. Terraform owns the job
# shape (infra/terraform/modules/db_migrate); the deploy pipeline owns this
# image's tag.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY alembic.ini ./
COPY migrations ./migrations

# The job runs the same revision history `make db-migrate` runs locally.
CMD ["alembic", "-c", "alembic.ini", "upgrade", "head"]
