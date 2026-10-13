#!/usr/bin/env bash
# QA gate: the QA-owned integration and acceptance suites (tests/**, qa/**).
#
# These are the "automated tests pass" promotion gate for Development
# (release.md "Environments & Promotion"). They boot the real services over HTTP
# — the same uvicorn modules and ports as `make boot` — and verify the delivered
# whole against the frozen contracts (CONTRACTS.md) and the feature acceptance
# criteria. A service that will not start fails here and its log is printed, so
# the failure is reproducible from the same command locally (`make qa`).
#
# Model-backed checks carry the `model` marker and are opt-in: a judged run needs
# the golden sets and the pinned-model credential, so it runs at the phase gate
# via `make qa-model`, not on every push (nfr.md "Measurement & Verification").
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

if ! has_python; then
  skip "no Python workspace to test against (services/**, ai/**)"
  exit 0
fi

paths=()
[ -d tests ] && paths+=(tests)
[ -d qa ] && paths+=(qa)
if [ "${#paths[@]}" -eq 0 ]; then
  skip "no QA suites yet (tests/**, qa/**)"
  exit 0
fi

log "QA · integration and acceptance suites (${paths[*]})"
"$(tool pytest)" "${paths[@]}" -m "not model"
