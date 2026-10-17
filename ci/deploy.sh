#!/usr/bin/env bash
# Deploy services to an environment (dev | staging | prod) on Cloud Run.
#
# Model (release.md "Deployment model"): canary for services. Each service is
# deployed with no traffic, then a candidate revision receives 5% of traffic.
# Promotion to 100% is a separate, deliberate step: `make promote ENV=... SVC=...`.
#
# Usage: ci/deploy.sh <env> [service ...]
#   env      dev | staging | prod
#   service  optional subset; default is every container image in the shared
#            registry (ci/lib.sh) — each service plus the model-serving image.
#
# Non-secret configuration comes from infra/terraform/environments/<env>.tfvars —
# the single per-environment source of truth. Secrets are never read here; Cloud
# Run injects them from Secret Manager.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:?usage: ci/deploy.sh <dev|staging|prod|pre-revenue> [service ...]}"
shift || true
case "$ENV" in
  dev|staging|prod|pre-revenue) ;;
  *) die "unknown environment '$ENV' (expected dev, staging, prod, or pre-revenue)" ;;
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

# The images to ship come from the shared registry (ci/lib.sh): every service
# directory carrying a Dockerfile, plus the model-serving image. An explicit
# service list on the command line narrows it; an unknown name is an error, not a
# silent skip, so a typo never deploys a partial release.
declare -A image_context image_dockerfile
image_names=()
while IFS='|' read -r name context dockerfile; do
  [ -n "$name" ] || continue
  image_names+=("$name")
  image_context[$name]="$context"
  image_dockerfile[$name]="$dockerfile"
done < <(container_images)

[ "${#image_names[@]}" -gt 0 ] \
  || die "no container images to deploy (services/*/Dockerfile, infra/docker/model.Dockerfile)"

if [ "$#" -gt 0 ]; then
  services=()
  for svc in "$@"; do
    [ -n "${image_context[$svc]:-}" ] || die "unknown service '$svc' (known: ${image_names[*]})"
    services+=("$svc")
  done
else
  services=("${image_names[@]}")
fi

log "Deploy · env=$ENV project=$PROJECT_ID region=$REGION tag=$GIT_SHA"
info "services: ${services[*]}"

# Apply the primary database migrations before any service traffic shifts, so a
# schema change lands before the code that expects it (release.md "Data
# migrations"). The job is Terraform-owned (modules/db_migrate); this replaces its
# image and runs it to completion — a failed migration stops the deploy.
if has_db_migrations && [ -f infra/db/Dockerfile ]; then
  migrate_image="${REGISTRY}/db-migrate:${GIT_SHA}"
  log "Deploy · build and push $migrate_image"
  docker build -f infra/db/Dockerfile -t "$migrate_image" infra/db
  docker push "$migrate_image"

  if ! gcloud run jobs describe scenova-db-migrate --project "$PROJECT_ID" --region "$REGION" >/dev/null 2>&1; then
    die "Cloud Run job 'scenova-db-migrate' not found in $PROJECT_ID; run 'make infra-apply ENV=$ENV' first"
  fi
  log "Deploy · update migration job scenova-db-migrate"
  gcloud run jobs update scenova-db-migrate \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --image "$migrate_image" \
    --quiet

  log "Deploy · run database migrations"
  bash "$(dirname "$0")/db.sh" cloud "$ENV"
fi

for svc in "${services[@]}"; do
  image="${REGISTRY}/${svc}:${GIT_SHA}"

  log "Deploy · build and push $image"
  docker build -f "${image_dockerfile[$svc]}" -t "$image" "${image_context[$svc]}"
  docker push "$image"

  log "Deploy · Cloud Run '$svc' (no traffic) + 5% canary"
  # The deploy pipeline owns the image tag; the platform (Terraform) owns the
  # service environment and secrets. `gcloud run deploy` with only --image keeps
  # the environment Terraform set — gcloud retains variables it is not asked to
  # change — and the running revision's commit is its image tag (`...:<sha>`),
  # which the run module leaves untouched (ignore_changes), so provenance
  # survives every apply. A variable injected here but not declared in
  # infra/terraform is drift: the next apply, or a lifecycle `start`, reconciles
  # the service to Terraform's environment set and strips it, and the running
  # revision silently loses it. Declare a new variable in Terraform instead; the
  # env schema check rejects a deploy that injects one.
  gcloud run deploy "$svc" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --image "$image" \
    --no-traffic \
    --tag candidate \
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
