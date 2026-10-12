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
