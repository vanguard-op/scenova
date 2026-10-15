"""event store, generation-job columns, and the build's idempotency ledgers

Carries the three stores the rest of the schema does not yet hold:

* `events` — the raw product-event store, the primary database's append-heavy
  half (architecture.md "Data Stores": raw product events; architecture.md
  "Analytics / Event Tracking": the intake writes each accepted event to the
  primary database before it is forwarded to the external analytics platform,
  so an event survives a restart of the intake). The columns are the event
  shape the taxonomy fixes (`analytics.md` "Event Taxonomy": the common
  properties on every event) plus the pseudonymous `user_id` the intake
  resolves from the caller's token, the received time the retention pass cuts
  on (`nfr.md` "Data lifecycle": lookup and usage events, 14 months, then
  aggregated; "Privacy & Compliance": anonymized on expiry), and the
  `consent_gated` flag ("Analytics Data Governance": events that describe
  reading behaviour are suppressed until consent is granted). Properties carry
  no personal data by rule, never a raw word or phrase (`analytics.md` "Event
  Taxonomy": Events reference `user_id`, never an email, name, the selected
  word, or the gloss phrase), so the store is not personal data — `user_id`
  is, and the deletion pass anonymizes it. Device history stays device-only
  (schema.md "DeviceHistoryEntry"), so no event for it can exist here.

* four `generation_jobs` columns the pipeline needs to persist a job and read
  it back by id (schema.md "GenerationJob" carries the first ten columns; these
  four are the transport facts the C-003 intake arrives with): the library key
  of the sense the job generates for (`sense_label`, `part_of_speech`), the
  clip duration the job targets, and the correlation id the job's generation
  events carry. Without them a job read back after a queue restart could not
  generate, write the word clip under its sense, or be traced to its lookup.

* `billing_events` and `applied_lookups` — the two idempotency ledgers the
  entitlement store applies its store billing events and its lookup metering
  through. A store billing event is recorded once however many times the
  processor redelivers its webhook, and a lookup is metered once however many
  times the client resends it, so a retried request never spends twice.
  Neither is a `schema.md` entity, so the schema does not name them; they are
  the build layer's own bookkeeping, and the tables are where their rows land.

Residency and retention (nfr.md "Privacy & Compliance") are carried by the
Cloud SQL instance: the fourteen-month raw-event window is applied by the
retention pass against the store, and the ledgers are bookkeeping rows that
grow with billing events and metered lookups rather than reader data.

Revision ID: 0003_events_and_ledgers
Revises: 0002_notify_persistence
Create Date: 2026-10-15
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0003_events_and_ledgers"
down_revision = "0002_notify_persistence"
branch_labels = None
depends_on = None

# Added in `upgrade`, dropped in reverse in `downgrade`; nothing else is touched.
TABLES = ("billing_events", "applied_lookups", "events")

# The `generation_jobs` columns this revision adds, and the backfill a row that
# predates this revision receives. The defaults are chosen so a row the column
# did not exist for can never round-trip into a state the store cannot hold:
# the possession is a valid sense key, the target duration is the four-second
# bound, and an empty correlation id is the value the store's record function
# for a legacy row without one.
JOB_COLUMNS = (
    "sense_label",
    "part_of_speech",
    "target_duration_seconds",
    "correlation_id",
)


def upgrade() -> None:
    # --- Raw product events (schema.md "Event Taxonomy"; NFR-040, NFR-041) ----

    op.create_table(
        "events",
        # The event's unique id, so a batch the client retried after a lost
        # response is stored once and a duplicate `event_id` is never appended
        # (C-007; `analytics.md` "Event Taxonomy": one event's unique id).
        sa.Column("event_id", sa.String(64), primary_key=True),
        # The EVT-### event name.
        sa.Column("name", sa.String(64), nullable=False),
        # The instant the event occurred, ISO-8601 UTC text, the convention
        # `0001_primary_schema` fixes.
        sa.Column("occurred_at", sa.String(64), nullable=False),
        # The pseudonymous identity the intake resolved from the caller's
        # token (C-007 `user_id`). The deletion pass swaps it for the sentinel
        # and severs the device and session ids, so the event can no longer be
        # re-linked to the reader who made it.
        sa.Column("user_id", sa.Text(), nullable=False),
        sa.Column("anonymous_id", sa.Text(), nullable=False),
        sa.Column("session_id", sa.Text(), nullable=False),
        sa.Column("platform", sa.String(16), nullable=False),
        sa.Column("app_version", sa.String(64), nullable=False),
        sa.Column("locale", sa.String(64), nullable=False),
        # The event's JSON properties. No property may carry personal data, so
        # the store can be scanned and kept within the governance rules.
        sa.Column("properties", sa.JSON(), nullable=False, server_default=sa.text("'{}'")),
        # The instant the intake accepted the event: the field the retention
        # pass cuts on, because the window is measured from receipt.
        sa.Column("received_at", sa.String(64), nullable=False),
        # Whether the event is one the client suppressed until consent ("Event
        # Taxonomy": events that describe reading behaviour are suppressed
        # until consent); the flag is what a pre-launch audit checks.
        sa.Column("consent_gated", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.CheckConstraint("platform IN ('android', 'ios')", name="ck_events_platform"),
    )
    # The retention pass cuts on receipt; the deletion pass resolves on the
    # subject; reporting resolves on the event name. An index each, no more.
    op.create_index("ix_events_received_at", "events", ["received_at"])
    op.create_index("ix_events_user_id", "events", ["user_id"])
    op.create_index("ix_events_name", "events", ["name"])

    # --- Generation-job columns (schema.md "GenerationJob"; C-003) ------------

    op.add_column(
        "generation_jobs",
        sa.Column("sense_label", sa.String(128), nullable=False, server_default=""),
    )
    op.add_column(
        "generation_jobs",
        sa.Column("part_of_speech", sa.String(16), nullable=False, server_default="other"),
    )
    op.add_column(
        "generation_jobs",
        sa.Column(
            "target_duration_seconds", sa.Float(), nullable=False, server_default=sa.text("4")
        ),
    )
    op.add_column(
        "generation_jobs",
        sa.Column("correlation_id", sa.String(64), nullable=False, server_default=""),
    )
    # The backfill defaults above exist only for rows that predate this
    # revision; the columns are written by the queue from the job the C-003
    # intake received, so a fresh insert has a value for each and no default
    # should stand in for a forgotten one.
    for column in JOB_COLUMNS:
        op.alter_column("generation_jobs", column, server_default=None)

    # --- The build's idempotency ledgers (billing, metering) -------------------

    op.create_table(
        "billing_events",
        # The natural key of the store's billing event: the account, the event
        # kind, the store product, and when it occurred (C-019). One row per
        # key is what sends a redelivered webhook back to 202 applied-once.
        sa.Column("key", sa.Text(), primary_key=True),
        sa.Column("applied_at", sa.String(64), nullable=False),
    )

    op.create_table(
        "applied_lookups",
        # The reader's token subject and the client's idempotency key: the same
        # pair the metered lookup is deduplicated on, so a resent create is
        # applied as a spend once and a retry replays the same allowance
        # record (C-001).
        sa.Column("subject", sa.Text(), primary_key=True),
        sa.Column("client_lookup_id", sa.Text(), primary_key=True),
        sa.Column("applied_at", sa.String(64), nullable=False),
    )


def downgrade() -> None:
    # Reverse the additions: the ledgers and the event store drop their tables,
    # the job columns drop in reverse so `generation_jobs` returns to the shape
    # `0001_primary_schema` left it in (release.md "Data migrations": every
    # migration ships a tested down-migration).
    for table in TABLES:
        op.drop_table(table)
    for column in JOB_COLUMNS:
        op.drop_column("generation_jobs", column)
