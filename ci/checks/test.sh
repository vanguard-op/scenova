#!/usr/bin/env bash
# Unit tests for every present workspace. Engineers own these; QA owns the
# integration and acceptance suites under tests/ and qa/ (run at the phase gate).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

ran=0

if has_python && find services ai -name 'test_*.py' -o -name '*_test.py' 2>/dev/null | grep -q .; then
  log "Python · pytest"
  "$(tool pytest)"
  ran=1
else
  skip "no Python tests found (services/**, ai/**)"
fi

if has_flutter && [ -d apps/mobile/test ]; then
  log "Flutter · flutter test"
  (cd apps/mobile && flutter test)
  ran=1
else
  skip "no Flutter tests found (apps/mobile/test)"
fi

if has_console && [ -d apps/console/test ]; then
  log "Console · flutter test"
  (cd apps/console && flutter test)
  ran=1
else
  skip "no console tests found (apps/console/test)"
fi

[ "$ran" -eq 1 ] || info "nothing to test yet"
