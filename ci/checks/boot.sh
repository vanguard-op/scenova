#!/usr/bin/env bash
# Boot check: start every present service and assert it serves GET /healthz.
# A service that will not start fails the build here and prints its log, so the
# failure is reproducible from the same command locally (`make boot`).
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

logs_dir="$(mktemp -d)"
pids=()
compose_up=0

cleanup() {
  for pid in ${pids[@]:-}; do kill "$pid" 2>/dev/null || true; done
  if [ "$compose_up" -eq 1 ]; then docker compose down >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

service_present() { [ -d "$1" ] && find "$1" -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null | grep -q .; }

boot_one() {
  local name="$1" dir="$2" module="$3" port="$4"
  [ -n "$port" ] || die "no port configured for '$name' (check .env)"
  local log_file="$logs_dir/$name.log"
  local pybin; pybin="$(py)"
  log "Boot · $name on :$port"
  ( cd "$dir" && exec "$pybin" -m uvicorn "$module" --host 127.0.0.1 --port "$port" --log-level info ) \
    >"$log_file" 2>&1 &
  local pid=$!
  pids+=("$pid")

  local i ok=0
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then ok=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done

  if [ "$ok" -ne 1 ]; then
    printf '\n----- %s did not start — log follows -----\n' "$name" >&2
    cat "$log_file" >&2 || true
    die "service '$name' failed the boot check on :$port"
  fi
  info "$name healthy"
}

any=0
for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name module _port_var <<<"$entry"
  if service_present "services/$name"; then
    any=1
    break
  fi
done

if service_present "ai"; then any=1; fi

# The review console (FEAT-015): bootable once its web bundle has been built
# (`make build` / `make bundle` produce it; `make ci` builds before it boots).
console_built=0
if has_console && [ -d apps/console/build/web ]; then
  console_built=1
  any=1
fi

if [ "$any" -eq 0 ]; then
  skip "no services to boot yet (services/**, ai/**)"
  exit 0
fi

# The primary database the docs define (architecture.md "Primary Database")
# handed to the services that read DATABASE_URL: the compose PostgreSQL is
# brought up and migrated through the single documented database path
# (`ci/db.sh`, which `make db-up` / `make db-migrate` drive) *before* the first
# service starts, so a store-backed request is answered by a serving database,
# not a graceful 503 (nfr.md "Degradation when a dependency fails") from a
# database that never came up.
#
# Docker missing is not an error — the services degrade and the boot check still
# proves they start — but a database that is here and will not start or will not
# take the migrations is: it would fail every store call underneath healthy
# /healthz endpoints. Failing here fails fast and prints ci/db.sh's output.
if [ -f docker-compose.yml ]; then
  if command -v docker >/dev/null 2>&1; then
    bash ci/db.sh up
    compose_up=1
    if has_db_migrations; then
      log "Boot · apply the primary database migrations"
      bash ci/db.sh migrate
    else
      warn "no migrations to apply (infra/db/migrations)"
    fi
    # Redis mirrors Memorystore for local parity (rate-limit counters, hot lookup
    # keys); no service consumes it yet, so a failure is a warning, not a stop.
    docker compose up -d redis >/dev/null 2>&1 || warn "redis not started (no service consumes it yet)"
  else
    warn "docker not available — the local database and cache were not started; database-backed stores answer unavailable"
  fi
fi

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r name module port_var <<<"$entry"
  if service_present "services/$name"; then
    boot_one "$name" "services/$name" "$module" "$(port_for "$port_var")"
  fi
done

if service_present "ai"; then
  boot_one "model" "ai" "$MODEL_MODULE" "$(port_for "$MODEL_PORT_VAR")"
fi

# The review console: serve the built web bundle and assert it comes up, so a
# console that will not start fails here and prints its log.
if [ "$console_built" -eq 1 ]; then
  port="$(port_for CONSOLE_PORT)"
  [ -n "$port" ] || die "no CONSOLE_PORT configured (check .env)"
  log "Boot · console on :$port"
  log_file="$logs_dir/console.log"
  ( cd apps/console/build/web && exec "$(py)" -m http.server "$port" --bind 127.0.0.1 ) \
    >"$log_file" 2>&1 &
  pid=$!
  pids+=("$pid")

  ok=0
  for i in $(seq 1 40); do
    if curl -fsS "http://127.0.0.1:$port/" 2>/dev/null | grep -qi '<script'; then ok=1; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done

  if [ "$ok" -ne 1 ]; then
    printf '\n----- console did not start — log follows -----\n' >&2
    cat "$log_file" >&2 || true
    die "review console failed the boot check on :$port"
  fi
  info "console healthy"
fi

log "Boot check passed"
