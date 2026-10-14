#!/usr/bin/env bash
# Local credential preflight for the documented local path (NFR-024).
#
# The services verify Firebase ID tokens and send to Firebase Cloud Messaging
# with Application Default Credentials, so no credential is stored in the
# repository. `make auth` sets that credential up on the developer's machine and
# proves it against the configured project, so a wrong project identifier fails
# loudly here instead of silently as a 401 at the gateway or a queued notice:
#   - Application Default Credentials exist (it signs in when they do not);
#   - the ADC quota project is the configured project (Remote Config and other
#     Firebase APIs refuse a user credential with no quota project);
#   - the project exists and is reachable by the active account;
#   - Firebase Authentication and Cloud Messaging are enabled on it;
#   - the FCM send path authorizes a send to it.
#
# It needs network access and a Google account, so it is not part of `make ci`
# (CI has no credentials) and not part of `make setup` (which stays offline).
# Run it once after `make setup`.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

PROJECT="${FIREBASE_PROJECT_ID:-}"
[ -n "$PROJECT" ] \
  || die "no project configured: set GCP_PROJECT_ID in .env (FIREBASE_PROJECT_ID, kept equal to it, is set by the Makefile and ci/lib.sh)"
command -v gcloud >/dev/null 2>&1 \
  || die "gcloud is required for local credentials: https://cloud.google.com/sdk/docs/install"
command -v curl >/dev/null 2>&1 || die "curl is required for the FCM send check"

log "Auth · project $PROJECT"

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  log "Auth · no Application Default Credentials — signing in"
  gcloud auth application-default login
fi

log "Auth · ADC quota project → $PROJECT"
gcloud auth application-default set-quota-project "$PROJECT" --quiet

if ! gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
  die "project '$PROJECT' does not exist, or the active account cannot reach it"
fi
info "project reachable"

if ! gcloud services list --enabled --project "$PROJECT" \
  --filter='config.name:identitytoolkit.googleapis.com' \
  --format='value(config.name)' 2>/dev/null | grep -q .; then
  die "Firebase Authentication (identitytoolkit.googleapis.com) is not enabled on '$PROJECT'"
fi
info "Firebase Authentication enabled"

# Prove the FCM send path authorizes a send to the configured project: mint the
# same short-lived ADC token the notification service mints and send a message
# with a deliberately invalid device token. The provider accepts the credential
# and the project and rejects only the token (400/404); a refused credential or
# the wrong project comes back as 401/403, which is the failure this catches.
token="$(gcloud auth application-default print-access-token)"
probe_url="https://fcm.googleapis.com/v1/projects/${PROJECT}/messages:send"
probe_body='{"message":{"token":"scenova-auth-preflight","notification":{"title":"Scenova","body":"preflight"}}}'
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

code="$(curl -sS -o "$body_file" -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${token}" \
  -H 'Content-Type: application/json' \
  -d "$probe_body" "$probe_url" || echo 000)"

case "$code" in
  400 | 404)
    info "FCM send path authorized (HTTP $code for the invalid probe token)"
    ;;
  401 | 403)
    printf '\n' >&2
    cat "$body_file" >&2 || true
    printf '\n' >&2
    die "the FCM send path refused the credential or project '$PROJECT' (HTTP $code)"
    ;;
  *)
    printf '\n' >&2
    cat "$body_file" >&2 || true
    printf '\n' >&2
    die "unexpected response from the FCM send path (HTTP $code)"
    ;;
esac

log "Auth check passed — $PROJECT is set up for Firebase Authentication and FCM"
