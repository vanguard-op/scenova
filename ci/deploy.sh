#!/usr/bin/env bash
# Deploy services to an environment (dev | staging | prod) on Cloud Run.
#
# Model (release.md "Deployment model"): canary for services. Each service is
# deployed with no traffic, then a candidate revision receives 5% of traffic.
# Promotion to 100% is a separate, deliberate step: `make promote ENV=... SVC=...`.
#
# Usage: ci/deploy.sh <env> [service ...]
#   env      dev | staging | prod
#   service  optional subset; default is every service directory present.
#
# Non-secret configuration comes from infra/terraform/environments/<env>.tfvars —
# the single per-environment source of truth. Secrets are never read here; Cloud
# Run injects them from Secret Manager.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:?usage: ci/deploy.sh <dev|staging|prod> [service ...]}"
shift || true
case "$ENV" in
  dev|staging|prod) ;;
  *) die "unknown environment '$ENV' (expected dev, staging, or prod)" ;;
esac

TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"

tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }

# The project is the per-environment one from the tfvars (the source of truth);
# DEPLOY_PROJECT_ID overrides it explicitly. The local `.env` project
# (GCP_PROJECT_ID) must never reach a deploy.
PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"
REPO="${GCP_ARTIFACT_REPO:-$(tfvar artifact_repo)}"
GIT_SHA="${GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}"

[ -n "$PROJECT_ID" ] || die "no project_id in $TFVARS"
[ -n "$REGION" ] || die "no region in $TFVARS"
[ -n "$REPO" ] || die "no artifact_repo in $TFVARS"

if [ "$#" -gt 0 ]; then
  services=("$@")
else
  services=()
  for dir in services/*/; do
    [ -d "$dir" ] || continue
    services+=("$(basename "$dir")")
  done
fi

[ "${#services[@]}" -gt 0 ] || die "no services to deploy (services/*/ is empty)"

log "Deploy · env=$ENV project=$PROJECT_ID region=$REGION tag=$GIT_SHA"
info "services: ${services[*]}"

for svc in "${services[@]}"; do
  dir="services/$svc"
  [ -f "$dir/Dockerfile" ] || { warn "no Dockerfile for '$svc' — skipped"; continue; }
  image="${REGISTRY}/${svc}:${GIT_SHA}"

  log "Deploy · build and push $image"
  docker build -t "$image" "$dir"
  docker push "$image"

  log "Deploy · Cloud Run '$svc' (no traffic) + 5% canary"
  gcloud run deploy "$svc" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --image "$image" \
    --no-traffic \
    --tag candidate \
    --set-env-vars "ENVIRONMENT=$ENV,GIT_SHA=$GIT_SHA" \
    --quiet

  gcloud run services update-traffic "$svc" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --to-tags "candidate=5" \
    --quiet
done

log "Deploy complete — canary at 5%. Promote with: make promote ENV=$ENV SVC=<service>"

# The review console is a static Flutter Web app on Firebase Hosting, not a Cloud
# Run service, so it deploys through its own path (FEAT-015). It is skipped, with
# a warning, when the console or the Firebase CLI is not present, so a service
# deploy never fails on the console's account.
if has_console; then
  if command -v firebase >/dev/null 2>&1; then
    log "Deploy · review console (Firebase Hosting)"
    bash "$(dirname "$0")/deploy_console.sh" "$ENV"
  else
    warn "firebase-tools not found — skipped the review console (install: npm install -g firebase-tools)"
  fi
fi
