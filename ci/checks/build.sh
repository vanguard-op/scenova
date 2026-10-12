#!/usr/bin/env bash
# Build every present workspace so a broken build fails here, not at deploy.
#   Python  : byte-compile the workspace (catches syntax/import-time breakage)
#   Services: container image build (Dockerfile in the service directory)
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

for dir in services/*/; do
  [ -d "$dir" ] || continue
  if [ -f "${dir}Dockerfile" ]; then
    name="$(basename "$dir")"
    log "Build · docker image for service '$name'"
    docker build -t "scenova/${name}:${GIT_SHA:-local}" "$dir"
    built_any=1
  fi
done

if has_flutter; then
  log "Build · flutter build apk --debug"
  (cd apps/mobile && flutter build apk --debug)
  built_any=1
fi

if [ "$built_any" -eq 0 ]; then
  skip "nothing to build yet"
fi
