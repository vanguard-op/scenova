#!/usr/bin/env bash
# Dependency and secret hygiene (NFR-024, NFR-028).
#   - pip-audit over pinned requirements: no known vulnerabilities.
#   - secret scan: no keys, tokens, or credentials in the repository.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

log "Security · pip-audit (requirements-dev.txt)"
"$(tool pip-audit)" -r requirements-dev.txt

while IFS= read -r req; do
  [ -n "$req" ] || continue
  log "Security · pip-audit ($req)"
  "$(tool pip-audit)" -r "$req"
done < <(find services ai -maxdepth 2 -name requirements.txt 2>/dev/null | sort)

log "Security · secret scan"
bash "$(dirname "$0")/secret_scan.sh"
