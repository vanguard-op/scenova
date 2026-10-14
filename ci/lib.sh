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

# --- Workspace detection -----------------------------------------------------
# The repo is a monorepo whose workspaces are added by their owning roles. A
# check runs only when its workspace exists, so the foundation is green before
# the first feature lands and becomes a hard gate the moment it does.

has_python() {
  find services ai -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null | grep -q .
}

has_flutter() { [ -f apps/mobile/pubspec.yaml ]; }

has_console() { [ -f apps/console/pubspec.yaml ]; }

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

py() { if [ -x "$VENV_DIR/bin/python" ]; then echo "$VENV_DIR/bin/python"; else echo "python3"; fi; }
tool() {
  local name="$1"
  if [ -x "$VENV_DIR/bin/$name" ]; then echo "$VENV_DIR/bin/$name"; else echo "$name"; fi
}

# --- Service registry --------------------------------------------------------
# The services the docs define (architecture.md "System Components"), with the
# module each exposes and the local port it binds. A service is booted when its
# package directory exists. Every service MUST expose GET /healthz.
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
