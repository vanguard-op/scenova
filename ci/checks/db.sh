#!/usr/bin/env bash
# Primary database check: the migrations apply to a real PostgreSQL, roll back,
# and re-apply, and the schema the services will use is present.
#
# It runs a throwaway PostgreSQL container (the same pinned image as
# docker-compose) on an ephemeral port, so a developer's own database is never
# touched and the check is repeatable anywhere docker is available. The
# documented command (`make db-migrate` → ci/db.sh) is what it drives, so a
# migration that fails here fails the same way on a laptop and in CI, and the
# container log is printed on failure.
#
# The down-migration is exercised on purpose (release.md "Data migrations": every
# migration ships a tested down-migration); the re-apply proves the up path is
# repeatable, and a second migration head would fail the check.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

if [ ! -d infra/db/migrations ]; then
  skip "no database migrations yet (infra/db/migrations)"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  skip "docker not available — skipping the database check"
  exit 0
fi

if [ ! -x "$VENV_DIR/bin/alembic" ]; then
  die "alembic is not installed — run 'make setup' first"
fi

image="${DB_CHECK_IMAGE:-postgres:16-alpine}"
container="scenova-db-check-$$"

cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "Database · start throwaway PostgreSQL ($image)"
# `-p 127.0.0.1::5432` lets the engine pick a free host port, so parallel runs
# never collide; the port is read back below.
container="$(docker run -d --name "$container" \
  -e POSTGRES_DB=scenova -e POSTGRES_USER=scenova -e POSTGRES_PASSWORD=scenova \
  -p 127.0.0.1::5432 "$image")"

# Wait until the server accepts connections over TCP — the path the migrations
# use. The probe is TCP, never the container's Unix socket (postgres_tcp_ready
# in lib.sh explains why the socket reports ready too early). The container is
# checked each pass so a bad image fails fast instead of waiting out the bound.
ready=0
for _ in $(seq 1 120); do
  if postgres_tcp_ready scenova scenova -- docker exec "$container"; then ready=1; break; fi
  docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q true || break
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  printf '\n----- database did not become ready — log follows -----\n' >&2
  docker logs "$container" >&2 || true
  die "throwaway PostgreSQL failed to start"
fi

port="$(docker port "$container" 5432/tcp | head -1 | sed 's/.*://')"
[ -n "$port" ] || die "could not read the throwaway PostgreSQL port"
export DATABASE_URL="postgresql+psycopg://scenova:scenova@127.0.0.1:${port}/scenova"
info "database ready on 127.0.0.1:${port}"

# The documented migration command, exactly as `make db-migrate` runs it.
migrate() { bash ci/db.sh "$@"; }

expected_tables=(
  accounts applied_lookups billing_events clip_assets entitlements events
  feedback generation_jobs library_entries lookup_generation_jobs
  lookup_senses lookups model_pins moderation_actions pending_notices
  purchases push_registrations reports review_items
)
app_table_count() {
  docker exec "$container" psql -U scenova -d scenova -tAc \
    "select count(*) from information_schema.tables \
     where table_schema='public' and table_name <> 'alembic_version'"
}

log "Database · migrate to head"
migrate migrate

tables="$(docker exec "$container" psql -U scenova -d scenova -tAc \
  "select table_name from information_schema.tables where table_schema='public'")"
for table in "${expected_tables[@]}"; do
  grep -qx "$table" <<<"$tables" || die "migration did not create table '$table'"
done
info "schema present: ${#expected_tables[@]} tables"
log "Database · rollback to base (down-migration path)"
migrate rollback base
remaining="$(app_table_count)"
[ "$remaining" = "0" ] || die "downgrade left $remaining application table(s) behind"
info "downgrade removed every application table"

log "Database · migrate to head again (up path is repeatable)"
migrate migrate
reapplied="$(app_table_count)"
[ "$reapplied" = "${#expected_tables[@]}" ] \
  || die "re-apply left $reapplied table(s), expected ${#expected_tables[@]}"

heads="$(migrate heads | grep -c '(head)' || true)"
[ "$heads" -eq 1 ] || die "expected exactly one migration head, found $heads (a branch needs merging)"

log "Database check passed"
