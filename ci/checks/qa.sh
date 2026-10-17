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
# the golden sets and the pinned-model credential, so the input checks run at the
# phase gate via `make qa-model` and the golden-set evaluation via
# `make model-bar`, not on every push (nfr.md "Measurement & Verification").
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

# The integration suite authenticates with the pre-account dev verifier (D-011):
# every request presents a pseudonymous `dev:<subject>` token. Pin the mode here
# so a developer's local `.env`, which may verify real Firebase ID tokens, cannot
# leak into the run and 401 the suite — the same command must behave the same on
# a laptop and in CI.
export AUTH_MODE=dev

# The store-backed check in the suite (the restart-survival run) needs the
# primary database. It boots the compose PostgreSQL itself when it finds one
# absent, but a container that was just started is not yet accepting
# connections, so that boot races the container's first start — the same flake
# the database check hit. Bring the database up through the documented path
# (`ci/db.sh up`, which waits for the TCP listener — postgres_tcp_ready in
# lib.sh) and hand the suite a serving database. Only a database this station
# started is torn down again, so a developer's own `make db-up` is left alone.
db_started_here=0
if [ -f docker-compose.yml ] && command -v docker >/dev/null 2>&1; then
  [ -n "$(docker compose ps -q postgres 2>/dev/null)" ] || db_started_here=1
  bash ci/db.sh up
fi
teardown_db() { [ "$db_started_here" -eq 1 ] && docker compose down >/dev/null 2>&1 || true; }
trap teardown_db EXIT

log "QA · integration and acceptance suites (${paths[*]})"
"$(tool pytest)" "${paths[@]}" -m "not model"
