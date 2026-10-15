#!/usr/bin/env bash
# Promote canary revisions to full traffic (release.md roll-forward).
# A roll-forward requires the release owner; the on-call engineer uses rollback.sh.
# Usage: ci/promote.sh <env> [service ...]   (default: every container image)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:?usage: ci/promote.sh <env> [service ...]}"
shift || true
TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }
# The project is the per-environment one from the tfvars (the source of truth);
# DEPLOY_PROJECT_ID overrides it explicitly. The local `.env` project
# (GCP_PROJECT_ID) must never reach a deploy.
PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
REGION="${GCP_REGION:-$(tfvar region)}"

declare -A known=()
image_names=()
while IFS='|' read -r name _context _dockerfile; do
  [ -n "$name" ] || continue
  known[$name]=1
  image_names+=("$name")
done < <(container_images)
[ "${#image_names[@]}" -gt 0 ] || die "no container images to promote"

if [ "$#" -gt 0 ]; then
  services=()
  for svc in "$@"; do
    [ -n "${known[$svc]:-}" ] || die "unknown service '$svc' (known: ${image_names[*]})"
    services+=("$svc")
  done
else
  services=("${image_names[@]}")
fi

for svc in "${services[@]}"; do
  log "Promote · $svc → 100% in $ENV ($PROJECT_ID/$REGION)"
  gcloud run services update-traffic "$svc" \
    --project "$PROJECT_ID" --region "$REGION" \
    --to-latest --quiet
  gcloud run services update-traffic "$svc" \
    --project "$PROJECT_ID" --region "$REGION" \
    --remove-tags candidate --quiet
done

log "Promoted ${#services[@]} service(s) to 100%"
