#!/usr/bin/env bash
# Roll back a service to its previous revision (release.md "Rollback procedure").
# The on-call engineer runs this without approval; target recovery is 2 hours.
# Usage: ci/rollback.sh <env> <service>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:?usage: ci/rollback.sh <env> <service>}"
SVC="${2:?usage: ci/rollback.sh <env> <service>}"
TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }
# The project is the per-environment one from the tfvars (the source of truth);
# DEPLOY_PROJECT_ID overrides it explicitly. The local `.env` project
# (GCP_PROJECT_ID) must never reach a deploy.
PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"

log "Rollback · listing revisions of $SVC in $ENV"
mapfile -t revisions < <(gcloud run revisions list \
  --service "$SVC" --project "$PROJECT_ID" --region "$REGION" \
  --sort-by '~metadata.creationTimestamp' --format 'value(metadata.name)')

[ "${#revisions[@]}" -ge 2 ] || die "no previous revision to roll back to for '$SVC'"
previous="${revisions[1]}"

log "Rollback · $SVC → $previous at 100%"
gcloud run services update-traffic "$SVC" \
  --project "$PROJECT_ID" --region "$REGION" \
  --to-revisions "${previous}=100" --quiet

log "Rolled back $SVC to $previous"
