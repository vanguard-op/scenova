#!/usr/bin/env bash
# Environment schema conformance.
#
# `.env.example` is the single documented source of truth for configuration.
# This check keeps it from drifting from the platform it describes (release.md
# "Rollout Phases & Feature Flags"; architecture.md "Data Architecture"):
#   - every release flag is declared with the doc's default in `.env.example`,
#     and set per environment in environments/<env>.tfvars with a boolean value;
#     an environment may raise a flag above its default (pre-revenue raises the
#     generation path while it is exercised), but the raise is declared in its
#     tfvars rather than flipped on the live services, so an apply reconciles to
#     it;
#   - a tfvars carries no FLAG_* key the doc does not define (a typo would
#     silently disable a kill switch);
#   - the clip-store variables the AI layer resolves are declared;
#   - the primary-database keys are declared and stay wired to the Terraform
#     that provides the store;
#   - the deploy injects no service environment variable, because the platform
#     owns the service environment and the next apply would strip what it set;
#   - no schema key is declared twice.
#
# It runs before the build in `make ci`, so a drifted schema fails fast.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

SCHEMA=".env.example"
[ -f "$SCHEMA" ] || die "environment schema missing: $SCHEMA"

# release.md "Rollout Phases & Feature Flags": each flag and the default it
# ships with. The doc defines the set; a flag is added or removed there first.
FLAG_DEFAULTS=(
  "FLAG_ENABLE_CLIP_VIEW=false"       # FEAT-008
  "FLAG_ENABLE_GENERATION=false"      # FEAT-005
  "FLAG_ENABLE_PHRASE_CLIP=false"     # FEAT-007
  "FLAG_ENABLE_OFFLINE_HISTORY=false" # FEAT-009
  "FLAG_ENABLE_PAID_TIER=false"       # FEAT-013
  "FLAG_SERVE_SEEDED_LIBRARY=true"    # FEAT-006, on at launch
)

# architecture.md "Data Architecture" (Object Storage + CDN): the clip-store
# variables the AI layer resolves. A local run serves from its own store; the
# cloud always uses the bucket.
CLIP_STORE_KEYS=(
  CLIP_BUCKET
  CLIP_CDN_BASE_URL
  CLIP_STORE_BACKEND
  CLIP_LOCAL_BASE_URL
  CLIP_LOCAL_DIR
)

log "Env schema · $SCHEMA"

schema_keys() { sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$SCHEMA"; }

dups="$(schema_keys | sort | uniq -d)"
if [ -n "$dups" ]; then
  die "duplicate key(s) in $SCHEMA: $(echo "$dups" | tr '\n' ' ')"
fi

for pair in "${FLAG_DEFAULTS[@]}"; do
  grep -qxF "$pair" "$SCHEMA" || die "$SCHEMA must declare the release default '$pair'"
done
for key in "${CLIP_STORE_KEYS[@]}"; do
  grep -qE "^${key}=" "$SCHEMA" || die "$SCHEMA is missing the clip-store key $key"
done

# architecture.md "Data Architecture" (Primary Database): the environment the
# services and the migration toolchain read. DATABASE_URL is the one name for the
# connection string — the local docker-compose Postgres locally, injected from
# Secret Manager in the cloud — and the DB_* parts describe the local instance
# docker-compose starts. The schema must stay wired to the platform it describes:
# the services receive DATABASE_URL, and the Cloud SQL instance keeps
# point-in-time recovery so account and entitlement data meets the 1-hour RPO
# (nfr.md "Availability & Reliability").
DB_KEYS=(
  DATABASE_URL
  DB_HOST
  DB_PORT
  DB_NAME
  DB_USER
  DB_PASSWORD
)
for key in "${DB_KEYS[@]}"; do
  grep -qE "^${key}=" "$SCHEMA" || die "$SCHEMA is missing the database key $key"
done
if [ -f infra/terraform/main.tf ]; then
  # The services receive DATABASE_URL from the secret map; the assignment may sit
  # inline in a map (`{ DATABASE_URL = ... }`) or on its own line, so match the
  # assignment wherever it appears rather than only at the start of a line.
  grep -qE 'DATABASE_URL[[:space:]]*=' infra/terraform/main.tf \
    || die "infra/terraform/main.tf must wire DATABASE_URL into the services"
  grep -q 'point_in_time_recovery_enabled = true' infra/terraform/modules/data/main.tf \
    || die "the Cloud SQL instance must keep point-in-time recovery for the 1-hour RPO (nfr.md)"
fi
info "database ok: ${#DB_KEYS[@]} keys; DATABASE_URL wired; point-in-time recovery on"

# One project, three names (architecture.md "Identity provider"; D-005): the
# Firebase project — the token audience the services verify and the FCM target
# the notification service sends to — and the Cloud Tasks project are the same
# Google project as GCP_PROJECT_ID. The services read FIREBASE_PROJECT_ID
# directly from the environment, so it is declared here (`.env` carries it to a
# service started from the file) rather than left to be derived at the call
# site; this check enforces that all three names resolve to the same value,
# because a mismatch rejects every valid Firebase token with a 401 or points FCM
# at the wrong project. The Makefile and ci/lib.sh also re-derive
# FIREBASE_PROJECT_ID and TASKS_PROJECT from GCP_PROJECT_ID so the running stack
# cannot use a divergent value.
project_id="$(sed -n 's/^GCP_PROJECT_ID=//p' "$SCHEMA" | head -n1)"
[ -n "$project_id" ] \
  || die "$SCHEMA must declare the project identifier GCP_PROJECT_ID"
for alias in FIREBASE_PROJECT_ID TASKS_PROJECT; do
  alias_value="$(sed -n "s/^${alias}=//p" "$SCHEMA" | head -n1)"
  [ -n "$alias_value" ] \
    || die "$SCHEMA must declare $alias (a service reads it from the environment)"
  [ "$alias_value" = "$project_id" ] \
    || die "$SCHEMA has $alias=$alias_value but GCP_PROJECT_ID=$project_id; they must agree"
done
info "project identifier ok: GCP_PROJECT_ID=$project_id (FIREBASE_PROJECT_ID, TASKS_PROJECT agree)"

# The review console's environment (FEAT-015): the operator console verifies
# against the same Firebase project as the reader client, so its project id must
# equal GCP_PROJECT_ID — a mismatch would have the console mint tokens the
# gateway refuses. The keys are required so the console's build is described in
# one place, the same as the reader app's.
CONSOLE_KEYS=(
  CONSOLE_REVIEW_API_BASE_URL
  CONSOLE_FIREBASE_PROJECT_ID
  CONSOLE_FIREBASE_AUTH_DOMAIN
  CONSOLE_FIREBASE_API_KEY
  CONSOLE_FIREBASE_APP_ID
  CONSOLE_FIREBASE_MESSAGING_SENDER_ID
  CONSOLE_PORT
)
for key in "${CONSOLE_KEYS[@]}"; do
  grep -qE "^${key}=" "$SCHEMA" || die "$SCHEMA is missing the console key $key"
done
console_project="$(sed -n 's/^CONSOLE_FIREBASE_PROJECT_ID=//p' "$SCHEMA" | head -n1)"
[ "$console_project" = "$project_id" ] \
  || die "$SCHEMA has CONSOLE_FIREBASE_PROJECT_ID=$console_project but GCP_PROJECT_ID=$project_id; they must agree"
info "console environment ok: CONSOLE_FIREBASE_PROJECT_ID=$console_project"

# Payments and store products (FEAT-013). RevenueCat wraps the stores (D-008), so
# no card data reaches the product (NFR-027). The RevenueCat identifiers and the
# store product catalog are declared here; the tier figures the entitlement
# service meters against (C-018, C-019) must also match its Terraform
# environment, so an allowance cannot mean one thing locally and another in the
# cloud. Prices are store-managed and localized (monetization.md "Payment &
# Billing"), so they are never declared.
PAYMENT_KEYS=(
  REVENUECAT_API_KEY
  REVENUECAT_WEBHOOK_AUTH
  REVENUECAT_PUBLIC_SDK_KEY_APP_STORE
  REVENUECAT_PUBLIC_SDK_KEY_PLAY_STORE
  REVENUECAT_ENTITLEMENT_ID
  REVENUECAT_OFFERING_ID
  PRODUCT_PRO_MONTHLY
  PRODUCT_PRO_ANNUAL
  PRODUCT_TOPUP_LOOKUPS
)
# What each tier grants, read by the entitlement service (C-018, C-019). The
# Terraform environment must carry the same values, so the allowance a reader is
# metered against cannot differ between a laptop and the cloud.
ENTITLEMENT_CONSTANTS=(
  "ENTITLEMENT_FREE_LOOKUPS=20"
  "ENTITLEMENT_PRO_LOOKUPS=50"
  "ENTITLEMENT_TOPUP_LOOKUPS=20"
  "ENTITLEMENT_TRIAL_DAYS=7"
)
for key in "${PAYMENT_KEYS[@]}"; do
  grep -qE "^${key}=" "$SCHEMA" || die "$SCHEMA is missing the payments key $key"
done
for pair in "${ENTITLEMENT_CONSTANTS[@]}"; do
  key="${pair%%=*}"
  value="${pair#*=}"
  grep -qxF "$pair" "$SCHEMA" || die "$SCHEMA must declare '$pair'"
  grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"${value}\"" infra/terraform/main.tf \
    || die "infra/terraform/main.tf must carry ${key} = \"${value}\" for the entitlement service"
done
info "payments ok: ${#PAYMENT_KEYS[@]} keys; ${#ENTITLEMENT_CONSTANTS[@]} tier figures in step with Terraform"

# The reader app's build path bakes the store client configuration at build time
# (FEAT-013; monetization.md "Pricing Tiers"). Every key the build path defines
# must be declared in the schema, so a build cannot silently ship an empty SDK key
# or product id; no secret may be a build input, so a store credential never lands
# in the app bundle (NFR-024, NFR-027); and no release flag may be a build input,
# because a flag is a runtime kill switch (release.md) and a build that pinned
# `enable_paid_tier` could not be reverted without a new store build.
for key in "${MOBILE_DEFINE_KEYS[@]}"; do
  grep -qE "^${key}=" "$SCHEMA" || die "$SCHEMA must declare the app build key $key"
  case "$key" in
    REVENUECAT_API_KEY | REVENUECAT_WEBHOOK_AUTH)
      die "the app build must not carry the secret $key" ;;
    FLAG_*)
      die "the app build must not carry the release flag $key (a kill switch is a runtime value)" ;;
  esac
done
info "app build store configuration ok: ${#MOBILE_DEFINE_KEYS[@]} keys, no secret, no flag"

info "schema ok: ${#FLAG_DEFAULTS[@]} flags, ${#CLIP_STORE_KEYS[@]} clip-store keys"

# --- Deploy path: the platform owns the service environment ------------------
# The deploy pipeline owns the image tag; the platform (Terraform) owns the
# service environment and secrets. A variable the deploy injects but Terraform
# does not declare is drift: the next `terraform apply`, or a lifecycle `start`,
# reconciles the service to Terraform's environment set and strips it, so the
# running revision silently loses the value. Keep the boundary single-owner — the
# deploy writes no service environment variable at all. The running revision's
# commit is its image tag (`...:<sha>`), which the run module leaves untouched
# (ignore_changes), so provenance survives every apply.
DEPLOY="ci/deploy.sh"
if [ -f "$DEPLOY" ]; then
  if grep -vE '^[[:space:]]*#' "$DEPLOY" | grep -qE -- '--(update|set)-env-vars|--env-vars-file'; then
    die "$DEPLOY injects service environment variables; the platform (Terraform) owns them — declare the variable in infra/terraform instead"
  fi
  info "deploy owns only the image tag: the service environment stays Terraform's"
fi

shopt -s nullglob
tfvars=(infra/terraform/environments/*.tfvars)
if [ "${#tfvars[@]}" -eq 0 ]; then
  skip "no per-environment tfvars to check"
  log "Env schema check passed"
  exit 0
fi

for f in "${tfvars[@]}"; do
  for pair in "${FLAG_DEFAULTS[@]}"; do
    key="${pair%%=*}"
    grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"(true|false)\"" "$f" \
      || die "$f is missing a boolean $key"
  done
  # The free-tier shape used to change no flag (D-034), so this check forced
  # every pre-revenue flag to equal the release default. That is no longer the
  # shape: pre-revenue declares the generation path on while it is exercised, so
  # forcing the default would fight the deployment and the flags could not be
  # switched on at all. The per-environment set is now allowed to deviate; the
  # guards that remain are the ones that catch a mistake — every flag declared
  # as a boolean, and no flag outside the release set (both below).
  while read -r key; do
    [ -n "$key" ] || continue
    known=0
    for pair in "${FLAG_DEFAULTS[@]}"; do
      if [ "$key" = "${pair%%=*}" ]; then
        known=1
        break
      fi
    done
    [ "$known" -eq 1 ] || die "$f declares unknown flag $key (release.md defines the flag set)"
  done < <(sed -n 's/^[[:space:]]*\(FLAG_[A-Z0-9_]*\)[[:space:]]*=.*/\1/p' "$f")
done
info "per-environment flags ok: ${#tfvars[@]} file(s)"

log "Env schema check passed"
