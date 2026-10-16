#!/usr/bin/env bash
# Terraform formatting and validation for the infrastructure under infra/terraform.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

if ! has_terraform; then
  skip "no Terraform yet (infra/terraform)"
  exit 0
fi

TF="${TERRAFORM:-terraform}"
if ! command -v "$TF" >/dev/null 2>&1; then
  skip "terraform not installed — skipping infra checks"
  exit 0
fi

log "Infra · terraform fmt -check -recursive"
"$TF" -chdir=infra/terraform fmt -check -recursive

log "Infra · terraform init -backend=false"
"$TF" -chdir=infra/terraform init -backend=false -input=false -no-color >/dev/null

log "Infra · terraform validate"
"$TF" -chdir=infra/terraform validate -no-color

# --- Pre-revenue shape (D-034) -----------------------------------------------
# The pre-revenue environment is the free-tier shape with no always-on
# infrastructure. Every invariant below is a silent monthly bill if it regresses
# (Memorystore ~$35, a Serverless VPC Access connector's two always-on VMs, an
# idle minimum Cloud Run instance, a load balancer), so the shape is asserted
# here and not merely documented. The lifecycle action starts, pauses, and
# destroys this environment; the teardown guards are asserted too, because a
# teardown may not lose the data (nfr.md "Privacy & Compliance").
PREREV="infra/terraform/environments/pre-revenue.tfvars"
if [ -f "$PREREV" ]; then
  prerev_has() { grep -qE "^[[:space:]]*$1[[:space:]]*=[[:space:]]*$2([[:space:]]|$)" "$PREREV"; }
  prerev_has enable_redis false \
    || die "$PREREV must set enable_redis = false (Memorystore has no free tier, D-034)"
  prerev_has gateway_min_instances 0 \
    || die "$PREREV must set gateway_min_instances = 0 (an idle minimum instance is billed, D-034)"
  prerev_has vpc_egress '"direct"' \
    || die "$PREREV must set vpc_egress = \"direct\" (a connector's two VMs bill 24/7, D-034)"
  prerev_has db_tier '"db-f1-micro"' \
    || die "$PREREV must set db_tier = \"db-f1-micro\" (the cheapest reachable PostgreSQL, D-034)"
  prerev_has data_deletion_policy '"PREVENT"' \
    || die "$PREREV must set data_deletion_policy = \"PREVENT\" (a teardown may not lose the data)"
  prerev_has deletion_protection true \
    || die "$PREREV must set deletion_protection = true (a teardown may not lose the data)"
  if grep -qE '^[[:space:]]*cdn_domain' "$PREREV"; then
    die "$PREREV must not set cdn_domain (no CDN: a load balancer bills hourly, D-034)"
  fi
  info "pre-revenue shape ok: no Redis, no CDN, no connector, no min instances; data guarded"
fi

log "Infra checks passed"
