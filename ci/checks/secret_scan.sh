#!/usr/bin/env bash
# Secret scan (NFR-024): fail if a credential-looking value is committed.
# Dependency-free on purpose so it runs identically everywhere. The scanner's own
# patterns are excluded from the scan.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

self="ci/checks/secret_scan.sh"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files | grep -v "^$self$" | grep -v '^\.env\.example$')
else
  mapfile -t files < <(find . -type f \
    -not -path './.git/*' -not -path './.venv/*' -not -path './docs/*' \
    -not -path "./$self" -not -name '.env.example')
fi

[ "${#files[@]}" -gt 0 ] || { skip "no tracked files to scan"; exit 0; }

patterns=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AIza[0-9A-Za-z_-]{35}'                       # Google API key
  '"type"[[:space:]]*:[[:space:]]*"service_account"'  # service-account JSON
  'AKIA[0-9A-Z]{16}'                            # AWS access key id
  'xox[baprs]-[0-9A-Za-z-]{10,}'                # Slack token
  'gh[pousr]_[0-9A-Za-z]{36,}'                  # GitHub token
  'sk-[A-Za-z0-9]{32,}'                         # generic API key
)

failed=0
for pat in "${patterns[@]}"; do
  hits="$(grep -EnI -- "$pat" "${files[@]}" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    printf '\033[1;31msecret pattern matched:\033[0m %s\n%s\n' "$pat" "$hits" >&2
    failed=1
  fi
done

[ "$failed" -eq 0 ] || die "possible secret committed — remove it and rotate the credential"
info "no credential patterns found in ${#files[@]} tracked files"
