#!/usr/bin/env bash
# Lifecycle for the pre-revenue environment (D-034): start, pause, and destroy
# the environment on demand, so the paid resources exist only during testing
# windows.
#
# Usage: ci/lifecycle.sh <start|pause|destroy> [env]     (env defaults to pre-revenue)
#
#   start    Apply the environment: runtime on, database running. Nothing here
#            is left billing while idle beyond Cloud SQL's disk.
#   pause    Stop the database (the one always-on paid resource) and leave the
#            runtime up — every Cloud Run service is scale-to-zero, so an idle
#            environment costs storage only and resumes on the next request.
#   destroy  Stop the database and remove the runtime (Cloud Run services and the
#            uptime check). The data stores, network, and secrets stay.
#
# What a teardown may not lose (nfr.md "Privacy & Compliance" data lifecycle):
# account and entitlement data lives for the life of the account, financial
# records for seven years, and shared library entries until retired. This script
# therefore never runs `terraform destroy`, never deletes the GCP project, and
# refuses to destroy an environment whose data stores do not carry the teardown
# guards (`deletion_protection = true`, `data_deletion_policy = "PREVENT"`). The
# data stores are only ever stopped, never removed.
#
# It is driven only by manual dispatch (`.github/workflows/lifecycle.yml`); it
# refuses to run in a non-dispatch Actions event, so it can never fire on a push.
#
# The project is always named explicitly — `--project <id>` and
# CLOUDSDK_CORE_PROJECT — never taken from the caller's gcloud default, which may
# point at an unrelated project.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ACTION="${1:?usage: ci/lifecycle.sh <start|pause|destroy> [env]}"
ENV="${2:-pre-revenue}"
case "$ACTION" in
  start | pause | destroy) ;;
  *) die "unknown action '$ACTION' (expected start, pause, or destroy)" ;;
esac

# Guard: never on a push (or any non-dispatch event). Locally GITHUB_EVENT_NAME is
# unset, so `make env-*` still works; in Actions only a manual dispatch passes.
if [ -n "${GITHUB_EVENT_NAME:-}" ] && [ "$GITHUB_EVENT_NAME" != "workflow_dispatch" ]; then
  die "the lifecycle runs on manual dispatch only (event: $GITHUB_EVENT_NAME)"
fi

TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
BACKEND="infra/terraform/backend/${ENV}.hcl"
[ -f "$BACKEND" ] || die "missing backend config $BACKEND (remote state for $ENV)"

tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }
tfvar_raw() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$TFVARS" | head -1; }

PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"
[ -n "$PROJECT_ID" ] || die "no project_id in $TFVARS"
[ -n "$REGION" ] || die "no region in $TFVARS"

# The project is named explicitly for every gcloud call, and pinned as the
# default for anything that reads it, so the caller's gcloud default (which may be
# an unrelated project) can never leak into this run.
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export DEPLOY_PROJECT_ID="$PROJECT_ID"

log "Lifecycle · $ACTION · env=$ENV project=$PROJECT_ID region=$REGION"

# --- Guards before anything is applied ---------------------------------------

# The teardown may not lose the data. Refuse to destroy an environment whose
# stateful resources are not guarded; the free-tier shape sets both. This runs
# before any tooling, so a mistaken `destroy` stops at the confirmation and
# nothing else.
if [ "$ACTION" = "destroy" ]; then
  policy="$(tfvar data_deletion_policy)"
  protection="$(tfvar_raw deletion_protection)"
  [ "$policy" = "PREVENT" ] \
    || die "$ENV sets data_deletion_policy='$policy'; refusing to destroy without the teardown guard (expected PREVENT)"
  [ "$protection" = "true" ] \
    || die "$ENV sets deletion_protection=$protection; refusing to destroy without Cloud SQL deletion protection"
  [ "${CONFIRM_DESTROY:-}" = "$ENV" ] \
    || die "destroy is guarded: set CONFIRM_DESTROY=$ENV to confirm (never run this by accident)"
  info "teardown guards present: data_deletion_policy=PREVENT, deletion_protection=true"
fi

TF="${TERRAFORM:-terraform}"
command -v "$TF" >/dev/null 2>&1 || die "terraform is required (see .devcontainer or CI setup)"
command -v gcloud >/dev/null 2>&1 || die "gcloud is required"

# The GCP project must be reachable and ours.
if ! gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null 2>&1; then
  die "cannot describe project $PROJECT_ID — is it created and is gcloud authenticated?"
fi
info "project $PROJECT_ID is reachable"

# Cloud SQL, Cloud Run, Secret Manager, Cloud Tasks, Artifact Registry, and
# Monitoring all require a billing account; the Firebase free tier (Auth,
# Hosting, FCM, Firestore) does not. Report it plainly rather than failing deep
# inside an apply.
billing="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo unknown)"
if [ "$billing" != "True" ]; then
  warn "billing is not attached to $PROJECT_ID (billingEnabled=$billing)"
  warn "Cloud SQL, Cloud Run, Secret Manager, Cloud Tasks, and Artifact Registry all need it; attach one before 'start':"
  warn "  gcloud billing projects link $PROJECT_ID --billing-account <OPEN_ACCOUNT_ID>"
  [ "$ACTION" = "start" ] && die "cannot start $ENV without billing attached"
fi

# The remote state bucket is the one resource Terraform cannot create for itself.
STATE_BUCKET="$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$BACKEND" | head -1)"
[ -n "$STATE_BUCKET" ] || die "no bucket in $BACKEND"
if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" --project "$PROJECT_ID" >/dev/null 2>&1; then
  warn "remote state bucket gs://${STATE_BUCKET} does not exist; create it once:"
  warn "  gcloud storage buckets create gs://${STATE_BUCKET} --project $PROJECT_ID --location $REGION --uniform-bucket-level-access"
  warn "  gcloud storage buckets update gs://${STATE_BUCKET} --versioning"
  die "cannot ${ACTION} $ENV without its remote state"
fi

# --- Apply -------------------------------------------------------------------

TF_DIR="infra/terraform"
log "Lifecycle · terraform init ($BACKEND)"
"$TF" -chdir="$TF_DIR" init -input=false -no-color -backend-config="backend/${ENV}.hcl" >/dev/null

# pause/destroy only make sense on an environment that exists; applying them on a
# fresh state would create the data stores instead of stopping them.
if [ "$ACTION" != "start" ]; then
  if ! "$TF" -chdir="$TF_DIR" state list 2>/dev/null | grep -q .; then
    die "$ENV has no state to ${ACTION}; run 'start' first"
  fi
fi

# The overrides are the lifecycle: they are not written back to the tfvars, so
# the environment file stays the source of truth for its shape and `start`
# (which applies no overrides) restores it.
case "$ACTION" in
  start)
    log "Lifecycle · apply (runtime on, database running)"
    "$TF" -chdir="$TF_DIR" apply -input=false -no-color -auto-approve \
      -var-file="environments/${ENV}.tfvars"
    ;;
  pause)
    log "Lifecycle · apply (database stopped; runtime kept, scale-to-zero)"
    "$TF" -chdir="$TF_DIR" apply -input=false -no-color -auto-approve \
      -var-file="environments/${ENV}.tfvars" \
      -var db_activation_policy=NEVER
    ;;
  destroy)
    log "Lifecycle · apply (runtime removed, database stopped; data kept)"
    "$TF" -chdir="$TF_DIR" apply -input=false -no-color -auto-approve \
      -var-file="environments/${ENV}.tfvars" \
      -var runtime_enabled=false \
      -var db_activation_policy=NEVER
    ;;
esac

case "$ACTION" in
  start)
    log "Started · $ENV (project $PROJECT_ID). Deploy the images with: make deploy ENV=$ENV"
    ;;
  pause)
    log "Paused · $ENV — the database is stopped and the runtime is scale-to-zero; data, network, and secrets kept"
    ;;
  destroy)
    log "Destroyed · $ENV runtime — the database is stopped and the data stores, network, and secrets are kept"
    ;;
esac
