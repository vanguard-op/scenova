#!/usr/bin/env bash
# Secret scan (NFR-024): fail if a credential-looking value is committed.
# Dependency-free on purpose so it runs identically everywhere. The scanner's own
# patterns are excluded from the scan.
#
# Firebase client configuration is exempt from the Google-API-key pattern only:
#   apps/mobile/android/app/google-services.json
#   apps/mobile/lib/firebase_options.dart
# The value those files carry is a Firebase *client* API key — a public project
# identifier, not a credential. It ships inside every app binary; access is
# enforced by Security Rules, App Check, and per-key API restrictions, not by
# keeping the value hidden. The files are required for the client build, so they
# stay tracked. The exemption is scoped to the client-key field on exactly those
# two paths: every other pattern still scans them, and the Google-API-key pattern
# still fires on a genuine key on any other line or in any other file.
#
# What is settled for the project's three client keys, read from the command line
# (`gcloud services api-keys list --project scenova-hq`, then `get-key-string` to
# match each key to its value): each carries the default Firebase API-target list
# — 27 services — and no application restriction: no Android package name or
# SHA-1 signing-certificate fingerprint, no iOS bundle ID, no browser referrer.
# What is not settled from the command line, and needs the console or the reader's
# signing certificate: adding those application restrictions. The signing
# certificate is deferred with store release signing, so the Android key's SHA-1
# binding waits with it; until then the API-target list, App Check, and Security
# Rules carry the exposure.
#
# GitHub's own secret scanning raises a `google_api_key` alert per key; the two
# paths are excluded from it by rule in .github/secret_scanning.yml, the same
# exemption this scanner applies.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

self="ci/checks/secret_scan.sh"

files=()
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  while IFS= read -r file; do
    files+=("$file")
  done < <(git ls-files | grep -v "^$self$" | grep -v '^\.env\.example$')
else
  while IFS= read -r file; do
    files+=("$file")
  done < <(find . -type f \
    -not -path './.git/*' -not -path './.venv/*' -not -path './docs/*' \
    -not -path "./$self" -not -name '.env.example')
fi

[ "${#files[@]}" -gt 0 ] || { skip "no tracked files to scan"; exit 0; }

# Firebase client-key exemption (NFR-024). An AIza match is exempt only when both
# the path and the field match — the generated client-key field on the two client
# config files. Anything else (a genuine Google API key on another line, or in
# any other file) still fails the scan.
google_api_key_pattern='AIza[0-9A-Za-z_-]{35}'   # Google API key
firebase_client_paths='apps/mobile/android/app/google-services\.json|apps/mobile/lib/firebase_options\.dart'
firebase_client_field="[^A-Za-z0-9_](\"current_key\"|apiKey)[[:space:]]*:[[:space:]]*[\"']AIza"
firebase_client_exempt="^(\./)?(${firebase_client_paths}):[0-9]+:.*${firebase_client_field}"

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  "$google_api_key_pattern"
  '"type"[[:space:]]*:[[:space:]]*"service_account"'  # service-account JSON
  'AKIA[0-9A-Z]{16}'                            # AWS access key id
  'xox[baprs]-[0-9A-Za-z-]{10,}'                # Slack token
  'gh[pousr]_[0-9A-Za-z]{36,}'                  # GitHub token
  'sk-[A-Za-z0-9]{32,}'                         # generic API key
  'sk_[A-Za-z0-9]{20,}'                         # RevenueCat server key (sk_, not sk-)
)

failed=0
for pat in "${patterns[@]}"; do
  hits="$(grep -EnI -- "$pat" "${files[@]}" 2>/dev/null || true)"
  if [ -n "$hits" ] && [ "$pat" = "$google_api_key_pattern" ]; then
    hits="$(printf '%s\n' "$hits" | grep -Ev -- "$firebase_client_exempt" || true)"
  fi
  if [ -n "$hits" ]; then
    printf '\033[1;31msecret pattern matched:\033[0m %s\n%s\n' "$pat" "$hits" >&2
    failed=1
  fi
done

[ "$failed" -eq 0 ] || die "possible secret committed — remove it and rotate the credential"
info "no credential patterns found in ${#files[@]} tracked files"
