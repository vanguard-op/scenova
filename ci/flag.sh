#!/usr/bin/env bash
# Set a release flag on an environment's services.
#
# release.md "Rollout Phases & Feature Flags": each flag is a runtime kill
# switch. release.md "Rollback & Roll-forward": disabling a flag is the fastest
# rollback path and is preferred (30-minute target), so it must be a documented,
# one-command action the on-call engineer can run without a new image.
#
# The flags reach the services as environment variables (Terraform `var.flags`);
# this updates the flag on every service in the environment and rolls a new
# revision, so it takes effect immediately. The per-environment tfvars stays the
# source of truth — restore it after the incident so the next plan agrees.
#
# Usage: ci/flag.sh <dev|staging|prod> <FLAG_NAME> <true|false>
#   e.g. ci/flag.sh prod FLAG_ENABLE_GENERATION false
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:?usage: ci/flag.sh <env> <FLAG_NAME> <true|false>}"
FLAG="${2:?usage: ci/flag.sh <env> <FLAG_NAME> <true|false>}"
VALUE="${3:?usage: ci/flag.sh <env> <FLAG_NAME> <true|false>}"

case "$ENV" in
  dev|staging|prod) ;;
  *) die "unknown environment '$ENV' (expected dev, staging, or prod)" ;;
esac
case "$VALUE" in
  true|false) ;;
  *) die "flag value must be true or false (got '$VALUE')" ;;
esac

TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }

# The flag must be one the environment defines; a typo would set an environment
# variable no service reads and silently leave the kill switch unarmed.
grep -Eq "^[[:space:]]*${FLAG}[[:space:]]*=" "$TFVARS" \
  || die "flag '$FLAG' is not defined in $TFVARS"

# The project is the per-environment one from the tfvars (the source of truth);
# DEPLOY_PROJECT_ID overrides it explicitly. The local `.env` project must never
# reach a deploy.
PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"
[ -n "$PROJECT_ID" ] || die "no project_id in $TFVARS"
[ -n "$REGION" ] || die "no region in $TFVARS"

while IFS='|' read -r name _context _dockerfile; do
  [ -n "$name" ] || continue
  log "Flag · $FLAG=$VALUE on '$name' in $ENV ($PROJECT_ID/$REGION)"
  gcloud run services update "$name" \
    --project "$PROJECT_ID" --region "$REGION" \
    --update-env-vars "${FLAG}=${VALUE}" --quiet
done < <(container_images)

log "Flag set — reconcile $TFVARS so the next plan agrees, then re-deploy if needed"
