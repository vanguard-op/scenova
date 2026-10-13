#!/usr/bin/env bash
# The full local CI run — identical to the CI job in .github/workflows/ci.yml,
# which invokes this through `make ci`. Cheap static checks first, then security,
# infra, build, the boot check, and the QA gate, so a broken change fails fast.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

log "Scenova CI · environment=${ENVIRONMENT} · commit=${GIT_SHA:-local}"

bash ci/checks/lint.sh
bash ci/checks/env_schema.sh
bash ci/checks/types.sh
bash ci/checks/test.sh
bash ci/checks/security.sh
bash ci/checks/infra.sh
bash ci/checks/build.sh
bash ci/checks/boot.sh
bash ci/checks/qa.sh

log "CI passed"
