#!/usr/bin/env bash
# Environment schema conformance.
#
# `.env.example` is the single documented source of truth for configuration.
# This check keeps it from drifting from the platform it describes (release.md
# "Rollout Phases & Feature Flags"; architecture.md "Data Architecture"):
#   - every release flag is declared with the doc's default, and set per
#     environment in environments/<env>.tfvars with a boolean value;
#   - a tfvars carries no FLAG_* key the doc does not define (a typo would
#     silently disable a kill switch);
#   - the clip-store variables the AI layer resolves are declared;
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

info "schema ok: ${#FLAG_DEFAULTS[@]} flags, ${#CLIP_STORE_KEYS[@]} clip-store keys"

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
