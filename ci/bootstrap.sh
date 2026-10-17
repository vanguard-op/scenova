#!/usr/bin/env bash
# One-time project bootstrap for an environment (D-034: the pre-revenue
# environment the lifecycle starts, pauses, and destroys on demand).
#
# This is the setup Terraform cannot do for itself, run once before the first
# `make env-start`:
#   1. the project must have billing attached — Cloud SQL, Cloud Run, Secret
#      Manager, Cloud Tasks, Artifact Registry, and Compute all bill, so none of
#      them can even be enabled without it;
#   2. the Google APIs the shape calls must be enabled (ci/lib.sh REQUIRED_APIS);
#   3. the remote state bucket must exist, because Terraform needs somewhere to
#      keep state before it can create anything;
#   4. the resources that already exist on the project must be adopted with
#      `terraform import`, so the first apply changes them instead of trying to
#      recreate them. On `scenova-hq`, a Firebase-initialised project, those are
#      the Hosting site, its Web App, and the Identity Platform config.
#
# Idempotent: re-running it changes nothing. The project is always named
# explicitly (`--project <id>` and CLOUDSDK_CORE_PROJECT), never the caller's
# gcloud default, which may point at an unrelated project.
#
# Usage: ci/bootstrap.sh [env]     (env defaults to pre-revenue)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:-pre-revenue}"
TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
BACKEND="infra/terraform/backend/${ENV}.hcl"
[ -f "$BACKEND" ] || die "missing backend config $BACKEND (remote state for $ENV)"

tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }

PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"
SITE_ID="$(tfvar console_site_id)"
STATE_BUCKET="$(sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' "$BACKEND" | head -1)"

[ -n "$PROJECT_ID" ] || die "no project_id in $TFVARS"
[ -n "$REGION" ] || die "no region in $TFVARS"
[ -n "$STATE_BUCKET" ] || die "no bucket in $BACKEND"

command -v gcloud >/dev/null 2>&1 || die "gcloud is required"

# The project is pinned as the default for every call in this run.
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export DEPLOY_PROJECT_ID="$PROJECT_ID"

log "Bootstrap · env=$ENV project=$PROJECT_ID region=$REGION"

gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null 2>&1 \
  || die "cannot describe project $PROJECT_ID — is it created and is gcloud authenticated?"
info "project $PROJECT_ID is reachable"

# --- Billing (everything below is gated on it) --------------------------------

billing="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo unknown)"
if [ "$billing" != "True" ]; then
  warn "billing is not attached to $PROJECT_ID (billingEnabled=$billing)"
  warn "Cloud SQL, Cloud Run, Secret Manager, Cloud Tasks, Artifact Registry, and Compute all need it:"
  warn "  gcloud billing projects link $PROJECT_ID --billing-account <OPEN_ACCOUNT_ID>"
  die "cannot bootstrap $ENV without billing attached"
fi
info "billing attached"

# --- APIs ---------------------------------------------------------------------

log "Bootstrap · enabling the APIs the shape calls"
gcloud services enable --project "$PROJECT_ID" "${REQUIRED_APIS[@]}"
info "enabled: ${REQUIRED_APIS[*]}"

# --- Remote state bucket ------------------------------------------------------

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --project "$PROJECT_ID" >/dev/null 2>&1; then
  info "state bucket gs://${STATE_BUCKET} already exists"
else
  log "Bootstrap · creating remote state bucket gs://${STATE_BUCKET}"
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project "$PROJECT_ID" --location "$REGION" --uniform-bucket-level-access
fi

# Version the state bucket so a bad write can be rolled back. `gcloud storage
# buckets update --versioning` exits 0 without enabling versioning on some SDK
# builds, so the JSON API is used — the same way the Web App id is read above.
# Ensured on every run, so a bucket created before this fix is corrected too.
if command -v curl >/dev/null 2>&1; then
  token="$(gcloud auth print-access-token 2>/dev/null || true)"
  if [ -n "$token" ]; then
    curl -s -o /dev/null -X PATCH \
      "https://storage.googleapis.com/storage/v1/b/${STATE_BUCKET}?project=${PROJECT_ID}" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
      -d '{"versioning":{"enabled":true}}'
    info "versioning enabled on gs://${STATE_BUCKET}"
  else
    warn "could not mint a token; enable versioning on gs://${STATE_BUCKET} manually"
  fi
else
  warn "curl not found; enable versioning on gs://${STATE_BUCKET} manually"
fi

# --- CI identity: Workload Identity Federation (NFR-024) ----------------------
# The deploy and lifecycle workflows authenticate to this project without a
# long-lived key: GitHub's OIDC token is exchanged for a short-lived access token
# for the deploy service account. Terraform owns the service account itself
# (infra/terraform: `scenova-deploy`); the pool, the provider, the impersonation
# binding, and the pipeline's project roles are created here because they are
# project-level, one-time, and tied to the repository — the same category as the
# billing check and the state bucket, and not something Terraform can create for
# itself. Idempotent: each step is skipped when it already exists.
#
# The provider's attribute condition pins the repository and the event, so a
# token minted for any other repository is refused, and so is one minted for a
# pull request: a `pull_request`-event token carries the *base* repository's
# `assertion.repository`, so the repository check alone would not refuse a fork's
# PR. GitHub does not issue OIDC tokens to fork PR workflows at all today, which
# is what actually refuses them; the event-name clause makes the pin refuse it
# itself, so the control does not rest on that provider behaviour. Only `push` and
# `workflow_dispatch` mint tokens here — the deploy and lifecycle workflows — so
# nothing legitimate is excluded (the CI workflow runs on `pull_request` but never
# requests `id-token`). The impersonation binding names the same repository, so
# only this repo's workflows can act as the deploy account. The workflows read the
# provider resource name and the account from repository variables
# (GCP_WORKLOAD_IDENTITY_PROVIDER, GCP_DEPLOY_SERVICE_ACCOUNT).
GITHUB_REPO="${GITHUB_REPO:-vanguard-op/scenova}"
WIF_POOL="${WIF_POOL:-github-actions}"
WIF_PROVIDER="${WIF_PROVIDER:-github}"
DEPLOY_ACCOUNT_ID="scenova-deploy"

# The provider's desired state, applied on every run so a provider created before
# a condition was tightened is brought in line rather than left as it was.
WIF_ATTRIBUTE_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref"
WIF_ATTRIBUTE_CONDITION="assertion.repository == '${GITHUB_REPO}' && (assertion.event_name == 'push' || assertion.event_name == 'workflow_dispatch')"

if [ -n "$GITHUB_REPO" ]; then
  log "Bootstrap · Workload Identity Federation for $GITHUB_REPO"

  if gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project "$PROJECT_ID" --location global >/dev/null 2>&1; then
    info "workload identity pool $WIF_POOL already exists"
  else
    gcloud iam workload-identity-pools create "$WIF_POOL" \
      --project "$PROJECT_ID" --location global \
      --display-name "GitHub Actions" \
      --description "OIDC federation for ${GITHUB_REPO} Actions (NFR-024)" --quiet
    info "created workload identity pool $WIF_POOL"
  fi

  if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$WIF_POOL" >/dev/null 2>&1; then
    info "workload identity provider $WIF_PROVIDER already exists"
  else
    gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
      --project "$PROJECT_ID" --location global --workload-identity-pool "$WIF_POOL" \
      --display-name "GitHub OIDC" \
      --issuer-uri "https://token.actions.githubusercontent.com" \
      --attribute-mapping "$WIF_ATTRIBUTE_MAPPING" \
      --attribute-condition "$WIF_ATTRIBUTE_CONDITION" --quiet
    info "created workload identity provider $WIF_PROVIDER"
  fi

  # Converge the provider onto the desired mapping and condition on every run, so
  # a repository bootstrapped before the event-name clause was added is refused
  # the same way a fresh one is. Idempotent: a provider already at the desired
  # state is rewritten with the same values.
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
    --project "$PROJECT_ID" --location global --workload-identity-pool "$WIF_POOL" \
    --attribute-mapping "$WIF_ATTRIBUTE_MAPPING" \
    --attribute-condition "$WIF_ATTRIBUTE_CONDITION" --quiet >/dev/null
  info "provider $WIF_PROVIDER pinned to repository + push/workflow_dispatch"

  PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
  DEPLOY_SA="${DEPLOY_ACCOUNT_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
  gcloud iam service-accounts add-iam-policy-binding "$DEPLOY_SA" \
    --project "$PROJECT_ID" \
    --role "roles/iam.workloadIdentityUser" \
    --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}" \
    --quiet >/dev/null
  info "bound $GITHUB_REPO to impersonate $DEPLOY_SA"

  # The pipeline's project roles. The deploy workflow pushes images, deploys
  # Cloud Run services, runs the migration job, and publishes the console to
  # Firebase Hosting; the lifecycle workflow runs the same Terraform the
  # environment is built from. The set is scoped to those resources rather than
  # project owner: run, artifact registry, Cloud SQL, network/service networking,
  # secret manager, Cloud Tasks, storage, Firebase, Identity Platform,
  # monitoring, logging, service accounts, project IAM, and Service Usage, plus
  # acting as the runtime service accounts a Cloud Run deploy binds.
  DEPLOY_ROLES=(
    roles/run.admin
    roles/artifactregistry.admin
    roles/cloudsql.admin
    roles/compute.networkAdmin
    roles/servicenetworking.networksAdmin
    roles/secretmanager.admin
    roles/cloudtasks.admin
    roles/storage.admin
    roles/firebase.admin
    roles/firebasehosting.admin
    roles/identitytoolkit.admin
    roles/monitoring.admin
    roles/logging.admin
    roles/iam.serviceAccountAdmin
    roles/iam.serviceAccountUser
    roles/resourcemanager.projectIamAdmin
    roles/serviceusage.serviceUsageAdmin
  )
  for role in "${DEPLOY_ROLES[@]}"; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member "serviceAccount:${DEPLOY_SA}" --role "$role" --condition=None --quiet >/dev/null
  done
  info "granted ${#DEPLOY_ROLES[@]} pipeline roles to $DEPLOY_SA"
fi

# --- Adopt the resources that already exist -----------------------------------
# On an already-initialised project the first apply would otherwise try to create
# the Hosting site, the Web App, and the Identity Platform config that are
# already there. `terraform import` brings them under management; the import is
# skipped for a resource already in state, so this stays idempotent.

TF="${TERRAFORM:-terraform}"
TF_DIR="infra/terraform"

import_if_absent() {
  local addr="$1" id="$2"
  if "$TF" -chdir="$TF_DIR" state show "$addr" >/dev/null 2>&1; then
    info "already managed: $addr"
    return 0
  fi
  log "Bootstrap · import $addr"
  "$TF" -chdir="$TF_DIR" import -input=false -no-color \
    -var-file="environments/${ENV}.tfvars" "$addr" "$id"
}

# The Firebase Web App id is not fixed by configuration; it is read back from the
# Firebase Management API (the project's web app). Empty when curl or the
# credential is unavailable, in which case the commands are printed for a manual
# import.
firebase_web_app_id() {
  command -v curl >/dev/null 2>&1 || return 0
  local token json
  token="$(gcloud auth print-access-token 2>/dev/null)" || return 0
  json="$(curl -s -H "Authorization: Bearer ${token}" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    "https://firebase.googleapis.com/v1beta1/projects/${PROJECT_ID}/webApps" 2>/dev/null)" || return 0
  printf '%s' "$json" | sed -n 's/.*"appId": *"\([^"]*\)".*/\1/p' | head -1
}

adopt_existing() {
  if ! command -v "$TF" >/dev/null 2>&1; then
    warn "terraform not found — run the imports printed below before 'make env-start'"
    return 0
  fi
  "$TF" -chdir="$TF_DIR" init -input=false -no-color -backend-config="backend/${ENV}.hcl" >/dev/null

  # Identity Platform is a project singleton, adopted once per project.
  import_if_absent "module.identity.google_identity_platform_config.this" "projects/${PROJECT_ID}"

  if [ -n "$SITE_ID" ]; then
    import_if_absent "module.console.google_firebase_hosting_site.console" \
      "projects/${PROJECT_ID}/sites/${SITE_ID}"
  fi

  local web_app_id
  web_app_id="$(firebase_web_app_id)"
  if [ -n "$web_app_id" ]; then
    import_if_absent "module.console.google_firebase_web_app.console" \
      "projects/${PROJECT_ID}/webApps/${web_app_id}"
  else
    warn "could not discover the Firebase Web App id; list it with 'firebase apps:list --project $PROJECT_ID' and import"
    warn "  module.console.google_firebase_web_app.console as projects/${PROJECT_ID}/webApps/<app-id>"
  fi
}

log "Bootstrap · adopting the resources that already exist"
adopt_existing

log "Bootstrap complete · $ENV (project $PROJECT_ID)"
info "start the environment with: make env-start"
