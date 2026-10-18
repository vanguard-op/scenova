#!/usr/bin/env bash
# Shared helpers for every check and deploy path.
#
# Sourced by the scripts in ci/ — never executed directly. Keeping the logic here
# means the local run (`make ci`) and the CI run (`.github/workflows/ci.yml`) are
# the same commands over the same detection rules; a failure is reproducible.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Output ------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
skip() { printf '\033[1;33mskip:\033[0m %s\n' "$*"; }

# --- Environment -------------------------------------------------------------
# `.env` is the local source of truth; in CI the values come from the workflow.
if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

# The committed schema's value for a key (`$1`), or empty. A build path uses it
# as the last resort so a client build finds the non-secret values the schema
# declares even when a developer's `.env` predates them — a stale `.env` would
# otherwise bake empty `--dart-define` values and ship a build that cannot reach
# a stack or sell a plan. It is a build-path fallback only: the services and the
# deploy scripts keep reading `.env`/the environment, so no runtime or deploy
# value is silently taken from the schema.
schema_value() {
  sed -n "s/^$1=//p" "$REPO_ROOT/.env.example" | head -n1
}

# One project identifier (see `.env.example`): the Firebase project — the token
# audience the services verify and the FCM target the notification service sends
# to — and the Cloud Tasks project are the same Google project as
# GCP_PROJECT_ID. Re-derived here after `.env` so the running stack cannot use a
# value that diverges from the project it is configured for, even if a
# developer's file carries a stale one (`make env` guards the schema itself).
if [ -n "${GCP_PROJECT_ID:-}" ]; then
  export FIREBASE_PROJECT_ID="$GCP_PROJECT_ID"
  export TASKS_PROJECT="$GCP_PROJECT_ID"
fi

ENVIRONMENT="${ENVIRONMENT:-dev}"
VENV="${VENV:-.venv}"
case "$VENV" in
  /*) VENV_DIR="$VENV" ;;
  *) VENV_DIR="$REPO_ROOT/$VENV" ;;
esac

# --- Google APIs the environment calls ---------------------------------------
# The single list of the APIs the Terraform shape needs on its project, enabled
# once per project by `make bootstrap` (ci/bootstrap.sh) and asserted by the
# lifecycle (ci/lifecycle.sh) before an apply. The Firebase and Identity
# Platform APIs (firebase*, identitytoolkit, firebasehosting), Cloud Storage,
# Logging, and Monitoring are already on for a Firebase-initialised project, so
# they are not listed; Cloud Run, Cloud Tasks, Secret Manager, Artifact
# Registry, and Compute all need billing attached before they can even be
# enabled. gcloud enables transitive dependencies (e.g. containerregistry for
# artifactregistry) and is a no-op for an API already on.
REQUIRED_APIS=(
  run.googleapis.com
  cloudtasks.googleapis.com
  secretmanager.googleapis.com
  artifactregistry.googleapis.com
  compute.googleapis.com
  sqladmin.googleapis.com
  servicenetworking.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
)

# The APIs in REQUIRED_APIS that are not enabled on the given project. Prints one
# per line. A call that fails (no permission) is skipped rather than reported as
# missing, so a limited CI identity does not produce a false failure; the caller
# checks it can list services at all first.
missing_apis() {
  local project="$1" api enabled
  for api in "${REQUIRED_APIS[@]}"; do
    enabled="$(gcloud services list --enabled --project "$project" \
      --filter="config.name:$api" --format='value(config.name)' 2>/dev/null)" || continue
    [ -n "$enabled" ] || printf '%s\n' "$api"
  done
}

# --- Workspace detection -----------------------------------------------------
# The repo is a monorepo whose workspaces are added by their owning roles. A
# check runs only when its workspace exists, so the foundation is green before
# the first feature lands and becomes a hard gate the moment it does.

has_python() {
  find services ai -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null | grep -q .
}

has_flutter() { [ -f apps/mobile/pubspec.yaml ]; }

has_console() { [ -f apps/console/pubspec.yaml ]; }

# The shared design system both apps import: its own tokens and components, and
# the token and contrast tests that hold the brand to the accessibility target
# (branding.md "Accessibility"). A nested package, so it is detected and checked
# on its own rather than through an app's dependency on it.
has_design() { [ -f packages/scenova_design/pubspec.yaml ]; }

has_terraform() { [ -d infra/terraform ] && find infra/terraform -name '*.tf' -print -quit 2>/dev/null | grep -q .; }

# The review console's build-time configuration (FEAT-015). Values come from
# `.env` locally and from the environment in CI, so the same build command runs
# in both; the Firebase client config is a public project identifier, not a
# credential (access is gated by the curator role and MFA, not by hiding these).
CONSOLE_DEFINE_KEYS=(
  CONSOLE_REVIEW_API_BASE_URL
  CONSOLE_FIREBASE_PROJECT_ID
  CONSOLE_FIREBASE_AUTH_DOMAIN
  CONSOLE_FIREBASE_API_KEY
  CONSOLE_FIREBASE_APP_ID
  CONSOLE_FIREBASE_MESSAGING_SENDER_ID
)

console_dart_defines() {
  local key
  for key in "${CONSOLE_DEFINE_KEYS[@]}"; do
    printf -- '--dart-define=%s=%s\n' "$key" "${!key:-}"
  done
}

# The reader app's build-time environment (FEAT-008, FEAT-013): the gateway the
# build reaches and the store client configuration it carries. Both are carried
# into the build as `--dart-define` values, so the same build command describes
# the same app everywhere.
#
# `SCENOVA_API_BASE_URL` is the gateway a per-environment client build bakes. It
# must be in the define set or the build path cannot point a build at its own
# stack: without it a build falls back to the deployed gateway compiled into the
# app, so an emulator reaches the live stack but a dev/staging/prod build cannot
# name its environment's gateway.
#
# The store client configuration: RevenueCat wraps the stores (D-008), so the
# client buys through its SDK and no card data reaches the product (NFR-027).
# These are RevenueCat's *public* client SDK keys — one per store — and the store
# product catalog from monetization.md "Pricing Tiers": the Pro subscription
# (monthly and annual) and the one-time lookup top-up. They are identifiers, not
# credentials, so they ship inside the app bundle the way the Firebase client
# config does; the RevenueCat server API key and webhook authorization are Secret
# Manager containers mounted on the entitlement service alone and are never a
# build input. The values come from `.env` locally and from the environment in
# CI, so the same build command describes the same app everywhere. Prices are
# store-managed and localized (monetization.md "Payment & Billing"), so none is
# baked in — only identifiers.
#
# The two SDK keys have no value in the schema: only the user can supply them
# from the RevenueCat dashboard. The entitlement, offering, and product
# identifiers do have values there — they are the product's own catalog, not the
# user's — so a build finds them without the user filling anything in, and a
# build that is missing only an SDK key for its store fails at the store client
# rather than shipping a store it cannot buy from.
#
# The define names are the schema names: one name, one meaning, everywhere
# (`.env.example`). `make env` holds this list to the schema and refuses a secret
# or a release flag in it.
MOBILE_DEFINE_KEYS=(
  SCENOVA_API_BASE_URL
  REVENUECAT_PUBLIC_SDK_KEY_APP_STORE
  REVENUECAT_PUBLIC_SDK_KEY_PLAY_STORE
  REVENUECAT_ENTITLEMENT_ID
  REVENUECAT_OFFERING_ID
  PRODUCT_PRO_MONTHLY
  PRODUCT_PRO_ANNUAL
  PRODUCT_TOPUP_LOOKUPS
)

mobile_dart_defines() {
  local key value
  for key in "${MOBILE_DEFINE_KEYS[@]}"; do
    value="${!key:-}"
    [ -n "$value" ] || value="$(schema_value "$key")"
    printf -- '--dart-define=%s=%s\n' "$key" "$value"
  done
}

py() { if [ -x "$VENV_DIR/bin/python" ]; then echo "$VENV_DIR/bin/python"; else echo "python3"; fi; }
tool() {
  local name="$1"
  if [ -x "$VENV_DIR/bin/$name" ]; then echo "$VENV_DIR/bin/$name"; else echo "$name"; fi
}

# --- Container readiness -----------------------------------------------------
# The readiness probe for a PostgreSQL container. It is deliberately over TCP
# (`-h 127.0.0.1`), never the container's Unix socket: the official postgres
# image runs a temporary server on the socket alone while it executes its init
# scripts, then shuts it down and starts the server that serves the published
# port. `pg_isready` with no host hits the socket, so it reports ready against
# that temporary server and a connection made right after it is closed by the
# shutdown — the "server closed the connection unexpectedly" flake. Probing the
# TCP listener waits for the server the caller will actually connect to.
#
# Usage: postgres_tcp_ready <user> <db> -- <exec-prefix...>
postgres_tcp_ready() {
  local user="$1" db="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  "$@" pg_isready -h 127.0.0.1 -U "$user" -d "$db" >/dev/null 2>&1
}

# Bounded wait on the probe above: a server that never comes up fails the caller
# after a fixed bound rather than hanging or being papered over by a hand-tuned
# sleep. Returns non-zero when the bound elapses.
wait_for_postgres_tcp() {
  local bound="$1"; shift
  local deadline=$(( SECONDS + bound ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    postgres_tcp_ready "$@" && return 0
    sleep 0.5
  done
  return 1
}

# --- Service registry --------------------------------------------------------
# The services the docs define (architecture.md "System Components"), with the
# module each exposes and the local port it binds. A service is booted when its
# package directory exists. Every service MUST expose GET /health — the path the
# platform probes; Cloud Run's front end answers /healthz itself before the
# request reaches the container, so a check on that path would mean nothing.
# Format: name|module|port_var  (module keeps its own colon, e.g. app.main:app)
SERVICES=(
  "gateway|app.main:app|GATEWAY_PORT"
  "lookup|app.main:app|LOOKUP_PORT"
  "pipeline|app.main:app|PIPELINE_PORT"
  "library|app.main:app|LIBRARY_PORT"
  "entitlement|app.main:app|ENTITLEMENT_PORT"
  "feedback|app.main:app|FEEDBACK_PORT"
  "analytics|app.main:app|ANALYTICS_PORT"
  "notification|app.main:app|NOTIFICATION_PORT"
)
MODEL_MODULE="app.main:app"
MODEL_PORT_VAR="MODEL_PORT"

port_for() { local var="$1"; echo "${!var:-}"; }

# --- Container images --------------------------------------------------------
# Every runtime component the deployment topology defines, as the single source
# of truth for what is built, booted, and shipped. Format: name|context|dockerfile.
#
#   - Each service carries its own Dockerfile in its directory
#     (`services/<name>/Dockerfile`), so the build context is the service itself.
#   - The model-serving component's code is `ai/`; its build definition is
#     platform-owned (`infra/docker/model.Dockerfile`) because the container is a
#     platform artifact. It is built with the `ai/` context so the service's own
#     code, bundled data, and prompt artifacts are what go into the image.
#
# `make build` builds these, `make deploy` ships them, and the deploy script tags
# each with the commit sha, so the image validated in CI is the one promoted.
has_model() { [ -d ai ] && find ai -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null | grep -q .; }

container_images() {
  local dir name
  for dir in services/*/; do
    [ -f "${dir}Dockerfile" ] || continue
    name="$(basename "$dir")"
    printf '%s|%s|%s\n' "$name" "$dir" "${dir}Dockerfile"
  done
  if has_model && [ -f infra/docker/model.Dockerfile ]; then
    printf '%s|%s|%s\n' "model" "ai/" "infra/docker/model.Dockerfile"
  fi
}

# Local image reference; the deploy path overrides the registry and tag.
image_ref() { printf 'scenova/%s:%s\n' "$1" "${GIT_SHA:-local}"; }

# The primary database migration image (infra/db). It is a Cloud Run job, not a
# service: it is built and shipped but never smoke-booted as a server. It is kept
# out of container_images() for exactly that reason.
has_db_migrations() {
  [ -d infra/db/migrations ] \
    && find infra/db/migrations -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null | grep -q .
}

db_migrate_image() { printf '%s|%s|%s\n' "db-migrate" "infra/db" "infra/db/Dockerfile"; }
