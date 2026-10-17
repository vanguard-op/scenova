#!/usr/bin/env bash
# Repository-level controls a public repository gets for free (NFR-024, NFR-028).
#
# These are GitHub repository settings, not files: they cannot be expressed in
# Terraform or in the workflows, so they live here the way ci/bootstrap.sh holds
# the project-level one-time setup. Run once per repository, and again whenever a
# control is added; every control is set to its desired state on each run.
#
# What each control is for:
#   secret scanning (alert mode)  the natural control behind the secret-scanning
#                                 obligation. The tracked Firebase client keys
#                                 (apps/mobile/android/app/google-services.json,
#                                 apps/mobile/lib/firebase_options.dart) are a
#                                 public project identifier, exempt by rule in
#                                 .github/secret_scanning.yml, so they raise no
#                                 alert; a genuine Google API key or any other
#                                 credential still does.
#   Dependabot alerts             known-vulnerability notices (NFR-028)
#   actions pinned to a SHA       every workflow action is already on a
#                                 full-length commit SHA (`.github/workflows`);
#                                 this turns on the repository's enforcement so a
#                                 tag reference fails the run. The pins are kept
#                                 current by .github/dependabot.yml.
#   branch ruleset on dev, main   blocks force-pushes and branch deletion. It
#                                 deliberately does NOT require pull requests:
#                                 the lead merges to main directly at a green
#                                 phase gate, and a PR rule would break that.
#
# Requires an authenticated `gh` with admin on the repository:
#   gh auth status
#
# Usage: ci/repo_controls.sh [owner/repo]     (default: vanguard-op/scenova)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

REPO="${1:-${GITHUB_REPO:-vanguard-op/scenova}}"
command -v gh >/dev/null 2>&1 || die "gh is required"

log "Repo controls · $REPO"

# --- Secret scanning (alert mode) --------------------------------------------
printf '%s' '{"security_and_analysis":{"secret_scanning":{"status":"enabled"}}}' \
  | gh api --method PATCH "repos/$REPO" --input - >/dev/null
info "secret scanning enabled (alert mode)"

# --- Dependabot alerts -------------------------------------------------------
gh api --method PUT "repos/$REPO/vulnerability-alerts" >/dev/null
info "Dependabot alerts enabled"

# --- Actions pinned to a full-length SHA -------------------------------------
printf '%s' '{"enabled":true,"allowed_actions":"all","sha_pinning_required":true}' \
  | gh api --method PUT "repos/$REPO/actions/permissions" --input - >/dev/null
info "actions pinned to a full-length SHA (sha_pinning_required)"

# --- Branch ruleset on dev and main ------------------------------------------
# Force-push and deletion are refused; pull requests are not required. Idempotent:
# the ruleset is updated in place when it already exists.
RULESET_NAME="protect-dev-main"
ruleset_id="$(gh api "repos/$REPO/rulesets" \
  --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || true)"
ruleset_payload="$(
  printf '{"name":"%s","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["refs/heads/dev","refs/heads/main"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"}]}' \
    "$RULESET_NAME"
)"
if [ -n "$ruleset_id" ]; then
  printf '%s' "$ruleset_payload" \
    | gh api --method PUT "repos/$REPO/rulesets/$ruleset_id" --input - >/dev/null
  info "ruleset $RULESET_NAME updated (dev, main)"
else
  printf '%s' "$ruleset_payload" \
    | gh api --method POST "repos/$REPO/rulesets" --input - >/dev/null
  info "ruleset $RULESET_NAME created (dev, main)"
fi

log "Repo controls applied · $REPO"
