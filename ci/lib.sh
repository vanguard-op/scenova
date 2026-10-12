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

has_terraform() { [ -d infra/terraform ] && find infra/terraform -name '*.tf' -print -quit 2>/dev/null | grep -q .; }

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
)
MODEL_MODULE="app.main:app"
MODEL_PORT_VAR="MODEL_PORT"

port_for() { local var="$1"; echo "${!var:-}"; }
