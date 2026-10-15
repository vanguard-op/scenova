#!/usr/bin/env bash
# Primary database migrations — the single entry point for local and cloud.
#
# The migration revisions under infra/db/migrations are the schema (Alembic
# history), and this script applies them the same way in both places:
#
#   Local   : DATABASE_URL points at the docker-compose Postgres (`make db-up`).
#   Cloud   : the migration runs inside the VPC against Cloud SQL, because the
#             instance has a private-only address (architecture.md "Deployment
#             Topology"). `cloud <env>` executes the environment's Cloud Run
#             migration job, which reads DATABASE_URL from Secret Manager.
#
# A migration carries an `upgrade` and a matching `downgrade` (release.md "Data
# migrations"); `rollback` and `reset` exercise the down path.
#
# Usage: ci/db.sh <command> [args]
#   up                  Start the local PostgreSQL (docker compose up -d postgres).
#   migrate [rev]       Apply migrations up to rev (default: head).
#   rollback [rev]      Downgrade to rev (default: one revision, `-1`).
#   reset               Downgrade to base, then migrate to head.
#   status              Show the current revision and the migration head(s).
#   heads               Show the migration head(s); more than one is a branch.
#   cloud <env>         Execute the environment's Cloud Run migration job.
set -euo pipefail

# A DATABASE_URL already present in the environment wins over `.env` (which
# lib.sh sources below), so a caller can point this at a throwaway database
# without editing the developer's file — the CI check does exactly that.
_db_url_override="${DATABASE_URL:-}"

. "$(dirname "$0")/lib.sh"

if [ -n "$_db_url_override" ]; then
  export DATABASE_URL="$_db_url_override"
fi

# Alembic is run from infra/db so its `alembic.ini` and `migrations/` resolve.
alembic() { ( cd infra/db && "$(tool alembic)" -c alembic.ini "$@" ); }

require_url() {
  [ -n "${DATABASE_URL:-}" ] \
    || die "DATABASE_URL is not set (copy .env.example to .env and run 'make db-up')"
}

cmd="${1:-migrate}"
shift || true

case "$cmd" in
  up)
    command -v docker >/dev/null 2>&1 || die "docker is required to run the local PostgreSQL"
    log "Database · docker compose up -d postgres"
    docker compose up -d postgres
    # Wait until the server accepts connections, so `make db-up && make db-migrate`
    # does not race the container's first start.
    for _ in $(seq 1 60); do
      docker compose exec -T postgres pg_isready \
        -U "${DB_USER:-scenova}" -d "${DB_NAME:-scenova}" >/dev/null 2>&1 && break
      sleep 1
    done
    info "PostgreSQL ready on ${DB_HOST:-localhost}:${DB_PORT:-5432} (docker compose)"
    ;;

  migrate)
    require_url
    rev="${1:-head}"
    log "Database · migrate to $rev"
    alembic upgrade "$rev"
    ;;

  rollback)
    require_url
    rev="${1:--1}"
    log "Database · rollback to $rev"
    alembic downgrade "$rev"
    ;;

  reset)
    require_url
    log "Database · reset (downgrade base, then head)"
    alembic downgrade base
    alembic upgrade head
    ;;

  status)
    require_url
    log "Database · current revision"
    alembic current
    log "Database · heads"
    alembic heads
    ;;

  heads)
    require_url
    alembic heads
    ;;

  cloud)
    env="${1:?usage: ci/db.sh cloud <dev|staging|prod>}"
    case "$env" in
      dev|staging|prod) ;;
      *) die "unknown environment '$env' (expected dev, staging, or prod)" ;;
    esac
    command -v gcloud >/dev/null 2>&1 || die "gcloud is required to run the cloud migration job"
    tfvars="infra/terraform/environments/${env}.tfvars"
    [ -f "$tfvars" ] || die "missing environment config $tfvars"
    tfvar() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\(.*\)\".*/\1/p" "$tfvars" | head -1; }
    project="${DEPLOY_PROJECT_ID:-$(tfvar project_id)}"
    region="${GCP_REGION:-$(tfvar region)}"
    [ -n "$project" ] || die "no project_id in $tfvars"
    log "Database · execute Cloud Run job scenova-db-migrate (env=$env project=$project)"
    # The job applies the same revisions against Cloud SQL from inside the VPC;
    # --wait fails this command when the migration fails, so a deploy stops
    # before traffic shifts onto a schema that did not apply.
    gcloud run jobs execute scenova-db-migrate \
      --project "$project" \
      --region "$region" \
      --wait \
      --quiet
    ;;

  *)
    die "unknown command '$cmd' (up | migrate | rollback | reset | status | heads | cloud)"
    ;;
esac
