#!/usr/bin/env bash
# Lint and format check for every present workspace.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

ran=0
if has_python; then
  log "Python · ruff check"
  "$(tool ruff)" check .
  log "Python · black --check"
  "$(tool black)" --check .
  ran=1
else
  skip "no Python workspace yet (services/**, ai/**)"
fi

if has_flutter; then
  log "Flutter · dart format --set-exit-if-changed"
  (cd apps/mobile && dart format --output=none --set-exit-if-changed .)
  log "Flutter · flutter analyze"
  (cd apps/mobile && flutter analyze)
  ran=1
else
  skip "no Flutter app yet (apps/mobile/pubspec.yaml)"
fi

if has_console; then
  log "Console · dart format --set-exit-if-changed"
  (cd apps/console && dart format --output=none --set-exit-if-changed .)
  log "Console · flutter analyze"
  (cd apps/console && flutter analyze)
  ran=1
else
  skip "no review console yet (apps/console/pubspec.yaml)"
fi

[ "$ran" -eq 1 ] || info "nothing to lint yet"
