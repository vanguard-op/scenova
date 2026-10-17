#!/usr/bin/env bash
# Traffic posture of an environment's Cloud Run services (release.md
# "Deployment model": a service serves one revision; a canary is a deliberate,
# temporary 5% that `make promote` closes).
#
# Read-only — it never shifts traffic. It fails when any service still splits
# traffic across revisions or still carries the `candidate` canary tag, so a
# half-promoted environment is caught rather than assumed settled. `make deploy`
# leaves a 5% canary by design (release.md "Rollout Phases & Feature Flags"), so
# run this after `make promote` to confirm the environment runs one version.
#
# It needs network access and Google credentials, so it is not part of `make ci`.
#
# Usage: ci/checks/traffic.sh <dev|staging|prod|pre-revenue>
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

ENV="${1:?usage: ci/checks/traffic.sh <env>}"
TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }

# The project is the per-environment one from the tfvars (the source of truth);
# DEPLOY_PROJECT_ID overrides it explicitly. Every gcloud call names it, so the
# caller's gcloud default (which may point at an unrelated project) can never
# leak into this run.
PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"
[ -n "$PROJECT_ID" ] || die "no project_id in $TFVARS"
[ -n "$REGION" ] || die "no region in $TFVARS"

command -v gcloud >/dev/null 2>&1 || die "gcloud is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

log "Traffic · env=$ENV project=$PROJECT_ID region=$REGION"

failed=0
while IFS='|' read -r svc _context _dockerfile; do
  [ -n "$svc" ] || continue

  if ! traffic="$(gcloud run services describe "$svc" \
      --project "$PROJECT_ID" --region "$REGION" \
      --format='json(status.traffic)' 2>/dev/null)"; then
    warn "$svc — could not read its traffic (service missing in $PROJECT_ID?)"
    failed=1
    continue
  fi

  # Every traffic entry carrying a percent is a revision the service serves. A
  # settled service has exactly one, at 100%, and no canary tag.
  served="$(jq -r '[.status.traffic[] | select((.percent // 0) > 0)] | length' <<<"$traffic")"
  tags="$(jq -r '[.status.traffic[].tag // empty] | join(", ")' <<<"$traffic")"
  summary="$(jq -r '[.status.traffic[] | "\(.percent)% \(.revisionName)\(if .tag then " [" + .tag + "]" else "" end)"] | join(", ")' <<<"$traffic")"

  if [ "$served" -eq 0 ]; then
    warn "$svc — serves no revision: $summary"
    failed=1
  elif [ "$served" -ne 1 ]; then
    warn "$svc — traffic split across $served revisions: $summary"
    failed=1
  elif [ -n "$tags" ]; then
    warn "$svc — one revision but a canary tag remains ($tags): $summary"
    failed=1
  else
    info "$svc — $summary"
  fi
done < <(container_images)

if [ "$failed" -ne 0 ]; then
  die "traffic is not settled — promote with 'make promote ENV=$ENV'"
fi

log "Traffic settled — every service serves one revision with no canary tag"
