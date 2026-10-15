#!/usr/bin/env bash
# Build every present workspace so a broken build fails here, not at deploy.
#   Python  : byte-compile the workspace (catches syntax/import-time breakage)
#   Images  : container image build, then a boot smoke test that asserts each
#             image serves GET /healthz (so an image that will not start fails
#             here and prints its log, not at deploy)
#   Flutter : debug APK build
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

built_any=0

# Start an image just built and assert it serves GET /healthz, printing the
# container log on failure. One fixed loopback port, used one container at a
# time, so the same command runs locally and in CI.
smoke_image() {
  local name="$1" image port=18080 cid log_file ok=0 i
  image="$(image_ref "$name")"
  log_file="$(mktemp)"
  # No --rm: a container that exits is kept so its log can be read on failure.
  cid="$(docker run -d -e PORT="$port" -p "127.0.0.1:${port}:${port}" "$image")"
  for i in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then ok=1; break; fi
    docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -q true || break
    sleep 0.5
  done
  docker logs "$cid" >"$log_file" 2>&1 || true
  docker rm -f "$cid" >/dev/null 2>&1 || true
  if [ "$ok" -ne 1 ]; then
    printf '\n----- image %s did not serve /healthz — log follows -----\n' "$image" >&2
    cat "$log_file" >&2 || true
    die "container image '$name' failed the boot smoke test"
  fi
  info "$name image healthy"
}

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
    smoke_image "$name"
    built_any=1
  done < <(container_images)
else
  skip "docker not available — skipping container image builds"
fi

if has_flutter; then
  # The reader app's build path carries the store client configuration (FEAT-013):
  # one command, shared with `make bundle`, bakes the RevenueCat public keys and
  # the store product catalog in so a build cannot ship without them.
  log "Build · reader app (store client configuration baked in)"
  bash "$REPO_ROOT/ci/build_app.sh" apk
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
