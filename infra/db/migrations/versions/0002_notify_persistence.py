"""notify persistence: push registrations and pending notices

Creates the durable half of the notification service's store (C-008, FEAT-008):
`push_registrations`, the device that took the notify offer for a lookup's clip,
and `pending_notices`, the clip-ready notice a push outage or restart delays
rather than loses (schema.md "PushRegistration", "PendingNotice"; nfr.md
"Availability & Reliability": the lookup path degrades, notices must not).

The tables carry what the notification service's port already associates in
memory and nothing else: token, platform, subject, and the lookup, and the clip
reference a notice delivers. A registration and its lookup's notices are removed
with the lookup they name (`ON DELETE CASCADE`, schema "Relationships": each is
removed with it); a delivered notice is deleted by the service, so no table
grows beyond what is undelivered.

While the intake takes the token itself, the duplicate key is the bounded
`device_token_hash` (SHA-256 hex), not the token: the intake accepts a token of
up to 4096 characters, and a unique index over the token at that width can
exceed PostgreSQL's b-tree entry limit at insert. A token belongs to one device,
so the hash is the same key and every index entry is short.

Device history is excluded on purpose: the reader's saved lookups live on the
device alone (schema.md "DeviceHistoryEntry"; nfr.md data lifecycle: device
history, on the device only), so no `raw_selection` for it is possible here —
the bound is carried by the device store, while the server-held one is the
`ck_lookups_raw_selection` check `0001_primary_schema` already applies.

Revision ID: 0002_notify_persistence
Revises: 0001_primary_schema
Create Date: 2026-10-15
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0002_notify_persistence"
down_revision = "0001_primary_schema"
branch_labels = None
depends_on = None

# Added in `upgrade`, dropped in reverse in `downgrade`; nothing else is touched.
TABLES = ("pending_notices", "push_registrations")


def upgrade() -> None:
    # --- Push registrations (C-008) -------------------------------------------

    op.create_table(
        "push_registrations",
        sa.Column("id", sa.Text(), primary_key=True),
        # The lookup the device asked to be notified about (C-008 `lookupId`).
        # Removed with the lookup (schema "Relationships": PushRegistration is
        # removed with it), so the cascade carries deletion and expiry.
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            nullable=False,
        ),
        # The caller's token subject: what the service store associates for each
        # registration, so a deletion request can strip the reader from it after
        # delivery (contract: C-008 auth; schema "PushRegistration").
        sa.Column("subject", sa.Text(), nullable=False),
        # The platform push token the notice is delivered to (C-008 `token`),
        # held for the send. The duplicate key below is the bounded SHA-256
        # digest `device_token_hash`, not this column: the intake accepts a
        # token of up to 4096 characters, and a unique index over it at that
        # width can exceed PostgreSQL's b-tree entry limit at insert. A token
        # belongs to one device, so the digest is the same key.
        sa.Column("device_token", sa.Text(), nullable=False),
        sa.Column("device_token_hash", sa.String(64), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "platform IN ('android', 'ios')", name="ck_push_registrations_platform"
        ),
        # The store is keyed by lookup and deduplicates a repeated device: a
        # reader may register the same token twice, and one row wins (C-008
        # `registered`).
        sa.UniqueConstraint(
            "lookup_id",
            "device_token_hash",
            "platform",
            name="uq_push_registrations_device",
        ),
    )
    # The delivery drain reads a lookup's registrations; the claim path is the
    # finished job id the clip-ready ingest is keyed by, not this column.
    op.create_index(
        "ix_push_registrations_lookup_id", "push_registrations", ["lookup_id"]
    )

    # --- Pending notices (C-008 payload) --------------------------------------

    op.create_table(
        "pending_notices",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            nullable=False,
        ),
        # Who the notice is delivered to and where the deliverable came from.
        sa.Column("device_token", sa.Text(), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        # The notice's data payload, exactly C-008's shape: the finished clip's
        # retrieval reference and its playing facts (contract: C-008). The word
        # and phrase are deliberately absent — the payload carries the lookup id,
        # so nothing about the reader's selection reaches the push provider.
        sa.Column("clip_url", sa.Text(), nullable=False),
        sa.Column("duration_seconds", sa.Float(), nullable=False),
        sa.Column("resolution", sa.String(16), nullable=False),
        sa.Column("has_audio", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint("platform IN ('android', 'ios')", name="ck_pending_notices_platform"),
        sa.CheckConstraint(
            "duration_seconds >= 3 AND duration_seconds <= 4",
            name="ck_pending_notices_duration",
        ),
        sa.CheckConstraint("resolution = '360p'", name="ck_pending_notices_resolution"),
    )
    # A push outage or a restart drains these oldest first, per lookup and token.
    op.create_index("ix_pending_notices_created_at", "pending_notices", ["created_at"])
    op.create_index("ix_pending_notices_lookup_id", "pending_notices", ["lookup_id"])


def downgrade() -> None:
    for table in TABLES:
        op.drop_table(table)
