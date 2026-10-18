"""a generation job's origin: the reader lookup or the entry it regenerates

D-037 and the revised C-003 fix a job's origin as exactly one of two: the
reader lookup that started it, or the library entry a report or a curator
regenerates. `0001_primary_schema` shaped `generation_jobs` with only the first
(`lookup_id NOT NULL`), so a report- or curator-started job — one that has no
reader lookup behind it — had no row it could be stored as, and the store
refused every such job on a store-backed deployment.

This revision carries the second origin (schema.md "GenerationJob": `entryId`
references the LibraryEntry a report or a curator started the job for, with
`lookupId` null on such a job; "Relationships": the two are set mutually
exclusively). It makes `lookup_id` nullable, adds `entry_id` referencing
`library_entries`, and adds the check that realizes "one of lookupId and entryId
is set and the other is null" in the store itself, so the 400 C-003 answers for
a job carrying both or neither is also a state the table cannot hold.

The origin decides how the finished clip is stored (C-003): a job with
`lookup_id` writes its clip to the shared library as a new entry; a job with
`entry_id` regenerates that entry, as the entry's candidate for a report or its
replacement for a curator's phrase edit. The clip-store path is the pipeline's,
not this migration's; this revision only makes the row represent the origin.

`entry_id` is removed with its entry (`ON DELETE CASCADE`, matching the existing
`lookup_id` cascade): a job that regenerates an entry has no meaning without
it, and a job removed with its only origin never leaves a row with no origin
set, which the new check would refuse. Nothing else in the table changes.

Revision ID: 0004_generation_job_origin
Revises: 0003_events_and_ledgers
Create Date: 2026-10-18
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0004_generation_job_origin"
down_revision = "0003_events_and_ledgers"
branch_labels = None
depends_on = None

# The constraint and index this revision adds to `generation_jobs`, named so the
# downgrade can drop exactly them.
ORIGIN_CHECK = "ck_generation_jobs_origin"
ENTRY_INDEX = "ix_generation_jobs_entry_id"


def upgrade() -> None:
    # The reader lookup is one of two possible origins, so a report- or
    # curator-started job legitimately has none (schema.md "GenerationJob":
    # `lookupId` is null for such a job). The foreign key and its cascade are
    # unchanged: a job with a lookup is still removed with it.
    op.alter_column(
        "generation_jobs",
        "lookup_id",
        existing_type=sa.String(64),
        nullable=True,
    )

    # The second origin: the library entry a report or a curator regenerates.
    # An inline foreign key, like `0001_primary_schema`'s own, so the column and
    # its reference land in one statement on PostgreSQL.
    op.add_column(
        "generation_jobs",
        sa.Column(
            "entry_id",
            sa.String(64),
            sa.ForeignKey("library_entries.id", ondelete="CASCADE"),
            nullable=True,
        ),
    )

    # Exactly one origin per job (schema.md "GenerationJob"; C-003's 400 for both
    # or neither). Enforced here so a store-backed deployment cannot record a job
    # the contract would have refused.
    op.create_check_constraint(
        ORIGIN_CHECK,
        "generation_jobs",
        "(lookup_id IS NULL) <> (entry_id IS NULL)",
    )

    # The entry side is read the way the lookup side is, and the cascade above
    # scans it on an entry's removal; `lookup_id` already carries its index.
    op.create_index(ENTRY_INDEX, "generation_jobs", ["entry_id"])


def downgrade() -> None:
    # The pre-origin schema has no column for an entry-regenerating job and
    # holds `lookup_id NOT NULL`, so those rows cannot survive the rollback
    # (release.md "Data migrations": every migration ships a tested
    # down-migration). A job is a transient queue row the pipeline re-enqueues
    # on the next request rather than durable data, so the rows the older shape
    # cannot represent are removed here, before the column they depend on goes.
    op.execute("DELETE FROM generation_jobs WHERE lookup_id IS NULL")

    op.drop_index(ENTRY_INDEX, table_name="generation_jobs")
    op.drop_constraint(ORIGIN_CHECK, "generation_jobs", type_="check")
    op.drop_column("generation_jobs", "entry_id")
    op.alter_column(
        "generation_jobs",
        "lookup_id",
        existing_type=sa.String(64),
        nullable=False,
    )
