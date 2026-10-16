#!/usr/bin/env bash
# Deploy the review console to Firebase Hosting (FEAT-015; architecture.md
# "Review Console").
#
# The console is a Flutter Web bundle served from its own Hosting site on the
# Firebase project the services already trust. It is a static site: no Cloud Run
# service, no runtime service account, no secret. Operator access is gated by the
# curator role and MFA at sign-in, not by a network boundary.
#
# Per-environment configuration comes from infra/terraform/environments/<env>.tfvars
# — the single source of truth for the environment. The Firebase *client* config
# is a public project identifier; the values the console reads are baked at build
# time from here, and anything left empty is taken at runtime from Hosting's
# `/__/firebase/init.json`. `.env`'s local console values never reach a deploy.
#
# Usage: ci/deploy_console.sh <dev|staging|prod|pre-revenue>
set -euo pipefail
. "$(dirname "$0")/lib.sh"

ENV="${1:?usage: ci/deploy_console.sh <dev|staging|prod|pre-revenue>}"
case "$ENV" in
  dev|staging|prod|pre-revenue) ;;
  *) die "unknown environment '$ENV' (expected dev, staging, prod, or pre-revenue)" ;;
esac

has_console || die "no review console to deploy (apps/console/pubspec.yaml is missing)"
command -v flutter >/dev/null 2>&1 || die "flutter is required to build the console"
command -v firebase >/dev/null 2>&1 \
  || die "firebase-tools is required to deploy (npm install -g firebase-tools)"

TFVARS="infra/terraform/environments/${ENV}.tfvars"
[ -f "$TFVARS" ] || die "missing environment config $TFVARS"
tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$TFVARS" | head -1; }

PROJECT_ID="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
FIREBASE_PROJECT="$(tfvar firebase_project_id)"
[ -n "$FIREBASE_PROJECT" ] || FIREBASE_PROJECT="$PROJECT_ID"
REGION="${GCP_REGION:-$(tfvar region)}"
SITE_ID="${CONSOLE_HOSTING_SITE:-$(tfvar console_site_id)}"
API_BASE="$(tfvar console_review_api_base_url)"

[ -n "$PROJECT_ID" ] || die "no project_id in $TFVARS"
[ -n "$REGION" ] || die "no region in $TFVARS"
[ -n "$SITE_ID" ] || die "no console_site_id in $TFVARS (or set CONSOLE_HOSTING_SITE)"

log "Deploy console · env=$ENV project=$PROJECT_ID site=$SITE_ID"

# The console authenticates against the Firebase project the services verify; a
# build pointed at a different project would mint tokens the gateway refuses. The
# optional client config is taken only from the deploy environment
# (CONSOLE_DEPLOY_FIREBASE_*), never from `.env`, so a local value cannot leak
# into a cloud build.
export CONSOLE_FIREBASE_PROJECT_ID="$FIREBASE_PROJECT"
export CONSOLE_FIREBASE_AUTH_DOMAIN="${FIREBASE_PROJECT}.firebaseapp.com"
export CONSOLE_REVIEW_API_BASE_URL="$API_BASE"
export CONSOLE_FIREBASE_API_KEY="${CONSOLE_DEPLOY_FIREBASE_API_KEY:-}"
export CONSOLE_FIREBASE_APP_ID="${CONSOLE_DEPLOY_FIREBASE_APP_ID:-}"
export CONSOLE_FIREBASE_MESSAGING_SENDER_ID="${CONSOLE_DEPLOY_FIREBASE_MESSAGING_SENDER_ID:-}"

log "Deploy console · flutter build web"
mapfile -t defines < <(console_dart_defines)
(cd apps/console && flutter build web "${defines[@]}")

# Firebase Hosting config, generated per deploy so the site id lives in exactly
# one place (the tfvars) and is never duplicated in the repository. The review
# endpoints (C-014 to C-016) are rewritten to the gateway so the console talks to
# the same origin and needs no CORS; everything else falls back to the SPA entry
# point.
firebase_dir="$REPO_ROOT/.firebase/console"
mkdir -p "$firebase_dir"
cat >"$firebase_dir/firebase.json" <<JSON
{
  "hosting": {
    "site": "${SITE_ID}",
    "public": "${REPO_ROOT}/apps/console/build/web",
    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
    "rewrites": [
      { "source": "/internal/review/**", "run": { "serviceId": "gateway", "region": "${REGION}" } },
      { "source": "**", "destination": "/index.html" }
    ],
    "headers": [
      {
        "source": "**/*.@(js|css|wasm)",
        "headers": [{ "key": "Cache-Control", "value": "public, max-age=31536000, immutable" }]
      },
      {
        "source": "/index.html",
        "headers": [{ "key": "Cache-Control", "value": "no-cache" }]
      }
    ]
  }
}
JSON

log "Deploy console · firebase deploy --only hosting"
firebase --config "$firebase_dir/firebase.json" --project "$PROJECT_ID" deploy --only hosting

log "Console deployed · https://${SITE_ID}.web.app"
