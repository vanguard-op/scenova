"""primary database schema

Creates the relational store the docs define for the primary database
(architecture.md "Data Architecture": accounts, entitlements, library entry
metadata, review records, and feedback; schema.md "Entities").

The tables realize the `schema.md` entities held in the primary store: Account,
Entitlement, Purchase, ClipAsset, LibraryEntry, GenerationJob, Lookup, Feedback,
Report, ReviewItem, ModerationAction, and ModelPin. Device history is device-only
(schema.md "DeviceHistoryEntry") and is never held here.

Two deliberate choices, both to keep this the one schema the services query
rather than a second, divergent one:

* Timestamps are stored as ISO-8601 UTC text, the form the entity models already
  carry (`date-time` in schema.md) and the services' rows map as `str`. The
  columns can move to `timestamptz` in a later migration if the services adopt
  datetime types.
* The lookup's resolved senses and pending generation jobs are child rows
  (`lookup_senses`, `lookup_generation_jobs`), so a reader's deletion removes
  them with the lookup instead of leaving the selection restated beside it
  (nfr.md "Privacy & Compliance").

Residency and retention (nfr.md "Privacy & Compliance") are carried by the Cloud
SQL instance (single primary region, encrypted at rest).

Revision ID: 0001_primary_schema
Revises:
Create Date: 2026-10-15
"""

from __future__ import annotations

import sqlalchemy as sa
from alembic import op

revision = "0001_primary_schema"
down_revision = None
branch_labels = None
depends_on = None

# Every table this migration creates. The downgrade drops them in reverse so
# foreign keys never block a rollback (release.md "Data migrations": a tested
# down-migration).
TABLES = (
    "accounts",
    "clip_assets",
    "library_entries",
    "lookups",
    "lookup_senses",
    "lookup_generation_jobs",
    "generation_jobs",
    "feedback",
    "reports",
    "review_items",
    "moderation_actions",
    "entitlements",
    "purchases",
    "model_pins",
)


def upgrade() -> None:
    # --- Account and entitlement (FEAT-013) -----------------------------------

    op.create_table(
        "accounts",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("email", sa.Text(), nullable=False),
        sa.Column("locale", sa.Text(), nullable=False),
        sa.Column(
            "consent_model_processing",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.Column("consent_updated_at", sa.Text(), nullable=True),
        sa.Column("created_at", sa.Text(), nullable=False),
        sa.Column("deleted_at", sa.Text(), nullable=True),
    )

    op.create_table(
        "entitlements",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "account_id",
            sa.Text(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("plan", sa.Text(), nullable=False),
        # The C-018 `trialEndsAt`: null unless the plan is trial (contract: C-018).
        sa.Column("trial_ends_at", sa.Text(), nullable=True),
        # Whether a paid subscription continues at the period end, so a
        # cancellation or a failed payment lets the paid period run out before
        # the reader reverts to free (monetization.md "Billing Events").
        sa.Column("renewing", sa.Boolean(), nullable=False, server_default=sa.text("false")),
        sa.Column("lookups_used", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("lookups_limit", sa.Integer(), nullable=False),
        sa.Column("period_start", sa.Text(), nullable=False),
        sa.Column("period_end", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("updated_at", sa.Text(), nullable=False),
        sa.CheckConstraint("plan IN ('free', 'trial', 'pro')", name="ck_entitlements_plan"),
        sa.CheckConstraint(
            "status IN ('active', 'grace', 'expired')", name="ck_entitlements_status"
        ),
        sa.CheckConstraint("lookups_used >= 0", name="ck_entitlements_lookups_used"),
        sa.CheckConstraint("lookups_limit >= 0", name="ck_entitlements_lookups_limit"),
        sa.UniqueConstraint("account_id", name="uq_entitlements_account"),
    )

    op.create_table(
        "purchases",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "account_id",
            sa.Text(),
            sa.ForeignKey("accounts.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("store", sa.Text(), nullable=False),
        sa.Column("product_id", sa.Text(), nullable=False),
        sa.Column("product_kind", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("amount_minor", sa.Integer(), nullable=False),
        sa.Column("currency", sa.Text(), nullable=False),
        sa.Column("purchased_at", sa.Text(), nullable=False),
        sa.Column("refunded_at", sa.Text(), nullable=True),
        sa.CheckConstraint("store IN ('app_store', 'play_store')", name="ck_purchases_store"),
        sa.CheckConstraint(
            "product_kind IN ('subscription', 'topup')", name="ck_purchases_product_kind"
        ),
        sa.CheckConstraint(
            "status IN ('active', 'refunded', 'failed')", name="ck_purchases_status"
        ),
        sa.CheckConstraint("amount_minor >= 0", name="ck_purchases_amount_minor"),
    )
    op.create_index("ix_purchases_account_id", "purchases", ["account_id"])

    # --- Shared word-clip library (FEAT-006, FEAT-011) ------------------------

    op.create_table(
        "clip_assets",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column("duration_seconds", sa.Float(), nullable=False),
        sa.Column("resolution", sa.String(16), nullable=False),
        sa.Column("storage_key", sa.String(1024), nullable=False),
        # The delivery URL and whether the clip has audio: the lookup serves both
        # on the reading path (contract: C-009 asset, C-001 clip).
        sa.Column("url", sa.String(2048), nullable=False),
        sa.Column("has_audio", sa.Boolean(), nullable=False),
        sa.Column("synth_id_watermark", sa.Boolean(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "duration_seconds >= 3 AND duration_seconds <= 4",
            name="ck_clip_assets_duration",
        ),
        sa.CheckConstraint("resolution = '360p'", name="ck_clip_assets_resolution"),
    )

    op.create_table(
        "library_entries",
        sa.Column("id", sa.String(64), primary_key=True),
        # The case-folded lemma the key is matched on; `lemma` keeps the form the
        # entry was stored under, for display (schema "LibraryEntry": the
        # normalised base form).
        sa.Column("lemma_key", sa.String(128), nullable=False),
        sa.Column("lemma", sa.String(128), nullable=False),
        sa.Column("part_of_speech", sa.String(16), nullable=False),
        sa.Column("sense_label", sa.String(128), nullable=False),
        sa.Column("gloss_phrase", sa.String(60), nullable=False),
        sa.Column("clip_asset_id", sa.String(64), sa.ForeignKey("clip_assets.id"), nullable=False),
        # The clip regenerated for a reporting reader, held beside the serving
        # clip until a curator chooses (FEAT-011, FEAT-015).
        sa.Column(
            "candidate_clip_asset_id",
            sa.String(64),
            sa.ForeignKey("clip_assets.id"),
            nullable=True,
        ),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("source", sa.String(16), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "part_of_speech IN ('noun', 'verb', 'adjective', 'adverb', 'preposition', 'other')",
            name="ck_library_entries_part_of_speech",
        ),
        sa.CheckConstraint(
            "status IN ('active', 'retired')", name="ck_library_entries_status"
        ),
        sa.CheckConstraint(
            "source IN ('seeded', 'generated')", name="ck_library_entries_source"
        ),
        # The library key: lemma and sense (schema "LibraryEntry"). A retired
        # entry keeps its key so a replacement upserts over it rather than
        # creating a second row for the same sense (C-009, C-011).
        sa.UniqueConstraint(
            "lemma_key",
            "sense_label",
            "part_of_speech",
            name="uq_library_entry_key",
        ),
    )
    op.create_index("ix_library_entries_status", "library_entries", ["status"])

    # --- Lookup path (FEAT-003, FEAT-006, FEAT-007) ---------------------------

    op.create_table(
        "lookups",
        sa.Column("id", sa.String(64), primary_key=True),
        # The caller's token subject: ownership and idempotency are scoped per
        # caller (contract: C-001, C-002). A deletion anonymizes the record
        # rather than severing the row (nfr.md "Privacy & Compliance").
        sa.Column("subject", sa.Text(), nullable=False),
        # The client's idempotency key. Nullable so a deletion can drop it; NULLs
        # compare distinct, so any number of anonymized rows sit under the
        # sentinel subject. A reuse with a different selection is a 409
        # (contract: C-001).
        sa.Column("client_lookup_id", sa.Text(), nullable=True),
        sa.Column(
            "account_id",
            sa.Text(),
            sa.ForeignKey("accounts.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("raw_selection", sa.Text(), nullable=False),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("normalised_lemma", sa.Text(), nullable=True),
        sa.Column(
            "served_entry_id",
            sa.String(64),
            sa.ForeignKey("library_entries.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("notice", sa.Text(), nullable=True),
        # The allowance the lookup was metered against, kept so a resent create
        # replays the same C-001 body; null for a reader who is not signed in.
        sa.Column("allowance_used", sa.Integer(), nullable=True),
        sa.Column("allowance_limit", sa.Integer(), nullable=True),
        sa.Column("allowance_period_end", sa.Text(), nullable=True),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint("kind IN ('word', 'phrase')", name="ck_lookups_kind"),
        sa.CheckConstraint(
            "status IN ('served', 'generating', 'fallback', 'denied', 'empty')",
            name="ck_lookups_status",
        ),
        sa.CheckConstraint("char_length(raw_selection) <= 80", name="ck_lookups_raw_selection"),
        sa.UniqueConstraint("subject", "client_lookup_id", name="uq_lookup_client"),
    )
    op.create_index("ix_lookups_subject", "lookups", ["subject"])
    op.create_index("ix_lookups_created_at", "lookups", ["created_at"])
    op.create_index("ix_lookups_served_entry_id", "lookups", ["served_entry_id"])

    op.create_table(
        "lookup_senses",
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("position", sa.Integer(), primary_key=True),
        sa.Column("sense_label", sa.Text(), nullable=False),
        sa.Column("part_of_speech", sa.String(16), nullable=False),
        sa.Column("gloss_phrase", sa.Text(), nullable=False),
        sa.Column("entry_id", sa.String(64), nullable=True),
        sa.Column("clip_url", sa.Text(), nullable=True),
        sa.Column("clip_duration_seconds", sa.Float(), nullable=True),
        sa.Column("clip_resolution", sa.String(16), nullable=True),
        sa.Column("clip_has_audio", sa.Boolean(), nullable=True),
    )

    op.create_table(
        "lookup_generation_jobs",
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("position", sa.Integer(), primary_key=True),
        sa.Column("job_id", sa.Text(), nullable=False),
    )

    op.create_table(
        "generation_jobs",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("lemma", sa.Text(), nullable=True),
        # Null while a word job is queued: the pipeline generates the phrase via
        # C-004 (contract: C-003 `phrase` is null for a word job).
        sa.Column("phrase", sa.Text(), nullable=True),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default=sa.text("0")),
        sa.Column("phrase_model", sa.Text(), nullable=False),
        sa.Column("clip_model", sa.Text(), nullable=False),
        sa.Column("cost_units", sa.Float(), nullable=False, server_default=sa.text("0")),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("completed_at", sa.String(64), nullable=True),
        sa.CheckConstraint("kind IN ('word', 'phrase')", name="ck_generation_jobs_kind"),
        sa.CheckConstraint(
            "status IN ('queued', 'running', 'succeeded', 'failed', 'declined')",
            name="ck_generation_jobs_status",
        ),
        sa.CheckConstraint("attempts >= 0", name="ck_generation_jobs_attempts"),
        sa.CheckConstraint("cost_units >= 0", name="ck_generation_jobs_cost_units"),
    )
    op.create_index("ix_generation_jobs_lookup_id", "generation_jobs", ["lookup_id"])
    op.create_index("ix_generation_jobs_status", "generation_jobs", ["status"])

    # --- Feedback and moderation (FEAT-010, FEAT-011, FEAT-015) ----------------

    op.create_table(
        "feedback",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("subject", sa.Text(), nullable=False),
        # The client's idempotency key; nullable so a deletion can drop it. A
        # reuse with a different rating is a 409 (contract: C-012).
        sa.Column("client_feedback_id", sa.Text(), nullable=True),
        sa.Column("rating", sa.Text(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "rating IN ('helpful', 'not_helpful', 'wrong')", name="ck_feedback_rating"
        ),
        sa.UniqueConstraint("subject", "client_feedback_id", name="uq_feedback_client_key"),
    )
    op.create_index("ix_feedback_lookup_id", "feedback", ["lookup_id"])

    op.create_table(
        "reports",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "lookup_id",
            sa.String(64),
            sa.ForeignKey("lookups.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("subject", sa.Text(), nullable=False),
        # The client's idempotency key; nullable so a deletion can drop it
        # (contract: C-013 `clientReportId`).
        sa.Column("client_report_id", sa.Text(), nullable=True),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        # The state the report's queue item resolves to (contract: C-013 `state`).
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "reason IN ('wrong_meaning', 'offensive', 'low_quality', 'other')",
            name="ck_reports_reason",
        ),
        sa.CheckConstraint(
            "status IN ('queued', 'reviewed', 'actioned')", name="ck_reports_status"
        ),
        sa.CheckConstraint("note IS NULL OR char_length(note) <= 300", name="ck_reports_note"),
        sa.UniqueConstraint("subject", "client_report_id", name="uq_reports_client_key"),
    )
    op.create_index("ix_reports_lookup_id", "reports", ["lookup_id"])

    op.create_table(
        "review_items",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "entry_id",
            sa.String(64),
            sa.ForeignKey("library_entries.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "candidate_clip_asset_id",
            sa.String(64),
            sa.ForeignKey("clip_assets.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("state", sa.Text(), nullable=False),
        # Whether the item's one report-triggered generation has started, so a
        # later report on the entry reuses the candidate instead of paying for a
        # second one (FEAT-011).
        sa.Column(
            "candidate_requested", sa.Boolean(), nullable=False, server_default=sa.text("false")
        ),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.Column("updated_at", sa.String(64), nullable=False),
        sa.Column("resolved_at", sa.String(64), nullable=True),
        sa.CheckConstraint(
            "state IN ('queued', 'reviewed', 'actioned')", name="ck_review_items_state"
        ),
        # One queue item per entry, however many reports it holds (C-014).
        sa.UniqueConstraint("entry_id", name="uq_review_items_entry"),
    )
    op.create_index("ix_review_items_state", "review_items", ["state"])

    op.create_table(
        "moderation_actions",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column(
            "entry_id",
            sa.String(64),
            sa.ForeignKey("library_entries.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "report_id",
            sa.Text(),
            sa.ForeignKey("reports.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("action", sa.Text(), nullable=False),
        sa.Column(
            "chosen_clip_asset_id",
            sa.String(64),
            sa.ForeignKey("clip_assets.id", ondelete="SET NULL"),
            nullable=True,
        ),
        sa.Column("actor_role", sa.Text(), nullable=False),
        sa.Column("phrase", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("created_at", sa.String(64), nullable=False),
        sa.CheckConstraint(
            "action IN ('choose', 'retire', 'edit_phrase')", name="ck_moderation_actions_action"
        ),
        sa.CheckConstraint(
            "phrase IS NULL OR char_length(phrase) <= 60", name="ck_moderation_actions_phrase"
        ),
        sa.CheckConstraint(
            "notes IS NULL OR char_length(notes) <= 500", name="ck_moderation_actions_notes"
        ),
    )
    op.create_index("ix_moderation_actions_entry_id", "moderation_actions", ["entry_id"])

    # --- Model pins (FEAT-004, FEAT-005, FEAT-007) ----------------------------

    op.create_table(
        "model_pins",
        sa.Column("id", sa.Text(), primary_key=True),
        sa.Column("model_id", sa.Text(), nullable=False),
        sa.Column("modality", sa.Text(), nullable=False),
        sa.Column("version", sa.Text(), nullable=False),
        sa.Column("pinned_at", sa.String(64), nullable=False),
        sa.Column("last_evaluated_at", sa.String(64), nullable=True),
        sa.Column("quality_status", sa.Text(), nullable=False),
        sa.CheckConstraint("modality IN ('text', 'video')", name="ck_model_pins_modality"),
        sa.CheckConstraint(
            "quality_status IN ('passing', 'failing', 'unevaluated')",
            name="ck_model_pins_quality_status",
        ),
    )


def downgrade() -> None:
    # Reverse dependency order, so no foreign key blocks the drop.
    for table in reversed(TABLES):
        op.drop_table(table)
