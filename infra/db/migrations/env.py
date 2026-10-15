"""Alembic environment for the Scenova primary database.

The database URL is read from DATABASE_URL — the same variable the services and
`make db-migrate` read — so the local docker-compose Postgres and the Cloud SQL
instance are migrated by one command with no committed credential (NFR-024).

``target_metadata`` is None on purpose: migrations are written explicitly, so the
schema is the migration history itself and no service model has to be importable
from the platform layer. A migration that adds a table or column is a new file
under ``versions/`` with an ``upgrade`` and a matching ``downgrade`` (release.md
"Data migrations").
"""

from __future__ import annotations

import os
from logging.config import fileConfig

from alembic import context
from sqlalchemy import engine_from_config, pool

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

target_metadata = None


def database_url() -> str:
    """The database URL, from DATABASE_URL; fail loudly when it is unset."""

    url = os.environ.get("DATABASE_URL", "").strip()
    if not url:
        raise RuntimeError(
            "DATABASE_URL is not set. Locally, copy .env.example to .env and run "
            "`make db-up`; in the cloud the migration job reads it from Secret Manager."
        )
    return url


def run_migrations_offline() -> None:
    """Emit the SQL for a migration without a live connection."""

    context.configure(
        url=database_url(),
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Apply migrations against a live connection."""

    section = config.get_section(config.config_ini_section, {})
    section["sqlalchemy.url"] = database_url()
    connectable = engine_from_config(section, prefix="sqlalchemy.", poolclass=pool.NullPool)

    with connectable.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
