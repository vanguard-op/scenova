#!/usr/bin/env bash
# Build every present workspace so a broken build fails here, not at deploy.
#   Python  : byte-compile the workspace (catches syntax/import-time breakage)
#   Images  : container image build (services/<name>/Dockerfile, and the
#             model-serving image from infra/docker/model.Dockerfile)
#   Flutter : debug APK build
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

built_any=0

if has_python; then
  py_dirs=()
  for d in services ai; do [ -d "$d" ] && py_dirs+=("$d"); done
  log "Build · Python byte-compile (${py_dirs[*]})"
  "$(py)" -m compileall -q "${py_dirs[@]}"
  built_any=1
else
  skip "no Python workspace to compile"
fi

if command -v docker >/dev/null 2>&1; then
  while IFS='|' read -r name context dockerfile; do
    [ -n "$name" ] || continue
    log "Build · docker image $(image_ref "$name")"
    docker build -f "$dockerfile" -t "$(image_ref "$name")" "$context"
    built_any=1
  done < <(container_images)
else
  skip "docker not available — skipping container image builds"
fi

if has_flutter; then
  log "Build · flutter build apk --debug"
  (cd apps/mobile && flutter build apk --debug)
  built_any=1
fi

if has_console; then
  log "Build · flutter build web (apps/console)"
  mapfile -t console_defines < <(console_dart_defines)
  (cd apps/console && flutter build web "${console_defines[@]}")
  built_any=1
fi

if [ "$built_any" -eq 0 ]; then
  skip "nothing to build yet"
fi
