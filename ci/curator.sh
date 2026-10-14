#!/usr/bin/env bash
# Grant or revoke the curator role on an operator's account (FEAT-015;
# architecture.md "Review Console"; nfr.md NFR-020, "multi-factor required for
# admin roles").
#
# The curator role is the `curator` custom claim on the operator's Firebase
# account — what the review service and the console check (C-014 to C-016). A
# session without it is refused and the attempt is logged (NFR-029). The role is
# granted here, out of band, because it belongs to a person, not to the platform:
# Terraform owns the MFA policy (infra/terraform/modules/identity); this owns the
# roster of people who hold the role.
#
# Usage: ci/curator.sh <email> [--revoke] [--force]
#   --revoke  remove the role instead of granting it
#   --force   grant the role even when the account has no second factor enrolled
#
# The gate: a curator session requires multi-factor authentication, so the role
# is refused unless the account already has a second factor enrolled. Enroll one
# in the console (or the Firebase console) first. --force exists only to
# bootstrap an operator who cannot reach the enrollment screen yet; the service
# still refuses a session that is not MFA-verified, so the gate holds regardless.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

EMAIL="${1:-}"
[ -n "$EMAIL" ] || die "usage: ci/curator.sh <email> [--revoke] [--force]"
shift || true
REVOKE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --revoke) REVOKE=1 ;;
    --force) FORCE=1 ;;
    *) die "unknown argument '$arg'" ;;
  esac
done

PROJECT="${FIREBASE_PROJECT_ID:-}"
[ -n "$PROJECT" ] \
  || die "no project configured: set GCP_PROJECT_ID in .env (FIREBASE_PROJECT_ID, kept equal to it, is derived by the Makefile and ci/lib.sh)"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v gcloud >/dev/null 2>&1 \
  || die "gcloud is required for the admin credential: https://cloud.google.com/sdk/docs/install"
command -v python3 >/dev/null 2>&1 || die "python3 is required to encode the API payloads"

TOKEN="$(gcloud auth application-default print-access-token)"
BASE="https://identitytoolkit.googleapis.com/v1/projects/${PROJECT}"

action="grant"
[ "$REVOKE" -eq 1 ] && action="revoke"
log "Curator · $PROJECT · $EMAIL ($action)"

lookup_body="$(python3 -c 'import json,sys; print(json.dumps({"email": [sys.argv[1]]}))' "$EMAIL")"
lookup="$(curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "$lookup_body" "${BASE}/accounts:lookup")" \
  || die "could not look up '$EMAIL' (is the account created and Firebase Authentication enabled?)"

read -r LOCAL_ID HAS_MFA < <(printf '%s' "$lookup" | python3 -c '
import json, sys
users = json.load(sys.stdin).get("users", [])
if not users:
    print("", "missing")
else:
    print(users[0].get("localId", ""), "yes" if users[0].get("mfaInfo") else "no")
')

[ -n "$LOCAL_ID" ] || die "no account for '$EMAIL' in $PROJECT"

if [ "$REVOKE" -eq 0 ] && [ "$HAS_MFA" != "yes" ] && [ "$FORCE" -eq 0 ]; then
  die "'$EMAIL' has no second factor enrolled; a curator session requires MFA (NFR-020). Enroll one first, or pass --force to grant the role for bootstrap."
fi
[ "$HAS_MFA" = "yes" ] && info "second factor enrolled" || info "no second factor enrolled"

if [ "$REVOKE" -eq 1 ]; then
  CLAIMS='{}'
else
  CLAIMS='{"curator":true}'
fi

update_body="$(LOCAL_ID="$LOCAL_ID" CLAIMS="$CLAIMS" python3 -c '
import json, os, time
print(json.dumps({
    "localId": os.environ["LOCAL_ID"],
    "customAttributes": os.environ["CLAIMS"],
    "validSince": str(int(time.time())),
}))
')"

# `validSince` invalidates existing refresh tokens, so a grant or revoke takes
# effect at the operator's next sign-in instead of whenever the current session
# happens to expire.
curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d "$update_body" "${BASE}/accounts:update" >/dev/null \
  || die "could not update the custom claims for '$EMAIL'"

if [ "$REVOKE" -eq 1 ]; then
  log "Curator role revoked from $EMAIL — existing sessions invalidated"
else
  log "Curator role granted to $EMAIL — existing sessions invalidated; the next sign-in carries the role"
fi
