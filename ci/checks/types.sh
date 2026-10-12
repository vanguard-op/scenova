#!/usr/bin/env bash
# Static type check for the Python workspace (DELIVERY: "typed").
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

if ! has_python; then
  skip "no Python workspace yet (services/**, ai/**) — mypy not run"
  exit 0
fi

log "Python · mypy"
"$(tool mypy)" .
