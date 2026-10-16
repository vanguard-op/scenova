# Scenova — platform commands.
#
# This Makefile is the single source of truth for how the project is set up,
# built, tested, booted, and deployed. CI runs exactly these targets (see
# ci/ci.sh and .github/workflows/ci.yml); the same command runs on a laptop and
# in the pipeline, so any failure is reproducible and its log readable.
#
# Non-secret configuration lives in .env (seeded from .env.example); per-cloud-
# environment configuration lives in infra/terraform/environments/<env>.tfvars.
# Secrets are never read here — they come from Secret Manager at runtime.

SHELL := /bin/bash
.DEFAULT_GOAL := help

-include .env
export

# One project identifier (see `.env.example`): the Firebase project — the token
# audience the services verify and the FCM target the notification service sends
# to — and the Cloud Tasks project are the same Google project as
# GCP_PROJECT_ID. Hard-assigned so a stale value left in a developer's `.env`
# cannot silently diverge and 401 every valid token (`make env` guards the schema
# itself).
FIREBASE_PROJECT_ID := $(GCP_PROJECT_ID)
TASKS_PROJECT := $(GCP_PROJECT_ID)
export FIREBASE_PROJECT_ID TASKS_PROJECT

VENV        ?= .venv
ENVIRONMENT ?= dev
ENV         ?= $(ENVIRONMENT)
# The pre-revenue environment (D-034) the lifecycle starts, pauses, and destroys.
LIFECYCLE_ENV ?= pre-revenue
GIT_SHA     ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo local)
TERRAFORM   ?= terraform
TF_DIR      := infra/terraform

PY        := $(VENV)/bin/python
PIP       := $(VENV)/bin/pip
BLACK     := $(VENV)/bin/black
RUFF      := $(VENV)/bin/ruff
MYPY      := $(VENV)/bin/mypy
PYTEST    := $(VENV)/bin/pytest

.PHONY: help setup auth fmt lint env typecheck test qa qa-model model-bar build bundle boot security \
        db-up db-migrate db-rollback db-reset db-status db-check db-migrate-cloud \
        infra-init infra-fmt infra-validate infra-plan infra-apply \
        bootstrap env-start env-pause env-destroy \
        deploy deploy-console curator promote rollback flag ci clean

help: ## Show the documented commands
	@printf '\nScenova platform commands (env=%s, venv=%s)\n\n' "$(ENVIRONMENT)" "$(VENV)"
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nTargets: make setup · make auth · make ci · make qa · make model-bar · make db-up · make db-migrate · make deploy ENV=staging · make promote ENV=staging SVC=gateway · make rollback ENV=staging SVC=gateway · make flag ENV=prod FLAG=FLAG_ENABLE_GENERATION VALUE=false · make curator OPERATOR=… · make bootstrap · make env-start · make env-pause · make env-destroy\n\n'

# --- Setup -------------------------------------------------------------------

setup: ## Create .venv, install pinned dev tooling, seed .env, fetch Flutter deps
	@set -e; \
	PYBIN="$$(command -v python3.12 || command -v python3)"; \
	echo "==> venv with $$PYBIN"; \
	$$PYBIN -m venv $(VENV); \
	$(PIP) install --quiet --upgrade pip; \
	$(PIP) install --quiet -r requirements-dev.txt; \
	for req in $$(find services ai infra/db -maxdepth 2 -name requirements.txt 2>/dev/null | sort); do \
		echo "==> deps $$req"; $(PIP) install --quiet -r "$$req"; \
	done; \
	if [ ! -f .env ]; then cp .env.example .env; echo "==> created .env from .env.example"; fi; \
	if [ -f packages/scenova_design/pubspec.yaml ]; then (cd packages/scenova_design && flutter pub get); else echo "==> skip: no shared design system yet"; fi; \
	if [ -f apps/mobile/pubspec.yaml ]; then (cd apps/mobile && flutter pub get); else echo "==> skip: no Flutter app yet"; fi; \
	if [ -f apps/console/pubspec.yaml ]; then (cd apps/console && flutter pub get); else echo "==> skip: no review console yet"; fi

auth: ## Set up local Application Default Credentials for the project (ADC + quota project) and verify it
	@bash ci/checks/auth.sh

# --- Quality gates -----------------------------------------------------------

fmt: ## Format Python (black) and Dart (dart format) in place
	@if find services ai -name '*.py' -not -path '*/.*' -print -quit 2>/dev/null | grep -q .; then \
		$(BLACK) .; $(RUFF) check --fix .; else echo "skip: no Python workspace"; fi
	@if [ -f packages/scenova_design/pubspec.yaml ]; then (cd packages/scenova_design && dart format .); else echo "skip: no shared design system"; fi
	@if [ -f apps/mobile/pubspec.yaml ]; then (cd apps/mobile && dart format .); else echo "skip: no Flutter app"; fi

lint: ## Lint Python (ruff) and Dart (flutter analyze), check formatting
	@bash ci/checks/lint.sh

env: ## Validate the environment schema (.env.example vs the release flags and clip store)
	@bash ci/checks/env_schema.sh

typecheck: ## Type-check the Python workspace (mypy)
	@bash ci/checks/types.sh

test: ## Run unit tests (pytest, flutter test)
	@bash ci/checks/test.sh

qa: ## Run the QA integration and acceptance suites (the development promotion gate)
	@bash ci/checks/qa.sh

qa-model: ## Run the QA model-marked gate checks (golden sets present; pinned-model credential)
	@if [ -d qa ]; then $(PYTEST) qa/ -m model; else echo "skip: no quality-bar harness (qa/)"; fi

model-bar: ## Run the model quality bar (BAR=NFR-050|NFR-051|NFR-053|all; ARGS="--ratings …")
	@bash ci/checks/model_bar.sh "$(BAR)" $(ARGS)

build: ## Build every present workspace (compile, container images + boot smoke, APK, console web)
	@bash ci/checks/build.sh

bundle: ## Produce deployable artifacts (container images; APK/appbundle; console web bundle)
	@bash ci/checks/build.sh
	@if [ -f apps/mobile/pubspec.yaml ]; then bash ci/build_app.sh appbundle; else echo "skip: no Flutter app"; fi

boot: ## Boot the stack locally (start the local Postgres, apply its migrations, hand them to the services) and assert each service serves /healthz
	@bash ci/checks/boot.sh

security: ## Dependency scan (pip-audit) and secret scan
	@bash ci/checks/security.sh

# --- Primary database --------------------------------------------------------

db-up: ## Start the local PostgreSQL (docker compose) for development
	@bash ci/db.sh up

db-migrate: ## Apply database migrations to the local DATABASE_URL
	@bash ci/db.sh migrate

db-rollback: ## Roll back one database migration (REV=… to target another revision)
	@bash ci/db.sh rollback $(REV)

db-reset: ## Rebuild the local schema (downgrade to base, then migrate to head)
	@bash ci/db.sh reset

db-status: ## Show the applied database revision and the migration head
	@bash ci/db.sh status

db-check: ## Apply, roll back, and re-apply the migrations against a throwaway PostgreSQL
	@bash ci/checks/db.sh

db-migrate-cloud: ## Run an environment's Cloud SQL migration job (ENV=dev|staging|prod)
	@bash ci/db.sh cloud $(ENV)

# --- Infrastructure ----------------------------------------------------------

infra-init: ## Initialise Terraform (download providers; no backend)
	$(TERRAFORM) -chdir=$(TF_DIR) init -backend=false -input=false

infra-fmt: ## Format Terraform
	$(TERRAFORM) -chdir=$(TF_DIR) fmt -recursive

infra-validate: ## Format-check and validate Terraform
	@bash ci/checks/infra.sh

infra-plan: ## Plan infrastructure for an environment (ENV=dev|staging|prod)
	$(TERRAFORM) -chdir=$(TF_DIR) init -input=false -backend-config=backend/$(ENV).hcl
	$(TERRAFORM) -chdir=$(TF_DIR) plan -var-file=environments/$(ENV).tfvars -out=$(ENV).tfplan

infra-apply: ## Apply infrastructure for an environment (ENV=dev|staging|prod|pre-revenue)
	$(TERRAFORM) -chdir=$(TF_DIR) apply -var-file=environments/$(ENV).tfvars

# --- Pre-revenue lifecycle (D-034) -------------------------------------------

bootstrap: ## One-time project setup: check billing, enable the APIs, create the state bucket, adopt existing resources (LIFECYCLE_ENV=pre-revenue)
	@bash ci/bootstrap.sh $(LIFECYCLE_ENV)

env-start: ## Start the pre-revenue environment (LIFECYCLE_ENV=pre-revenue)
	@bash ci/lifecycle.sh start $(LIFECYCLE_ENV)

env-pause: ## Pause the pre-revenue environment: stop the database, keep the runtime (LIFECYCLE_ENV=…)
	@bash ci/lifecycle.sh pause $(LIFECYCLE_ENV)

env-destroy: ## Destroy the pre-revenue runtime: stop the database, keep the data (LIFECYCLE_ENV=… CONFIRM_DESTROY=…)
	@bash ci/lifecycle.sh destroy $(LIFECYCLE_ENV)

# --- Release -----------------------------------------------------------------

deploy: ## Deploy container images to an environment (ENV=dev|staging|prod)
	@bash ci/deploy.sh $(ENV)

deploy-console: ## Deploy the review console to Firebase Hosting (ENV=dev|staging|prod)
	@bash ci/deploy_console.sh $(ENV)

curator: ## Grant or revoke the curator role on an operator's account (OPERATOR=email [ARGS=--revoke])
	@bash ci/curator.sh $(OPERATOR) $(ARGS)

promote: ## Promote a canary service to full traffic (ENV=… SVC=…)
	@bash ci/promote.sh $(ENV) $(SVC)

rollback: ## Roll a service back to its previous revision (ENV=… SVC=…)
	@bash ci/rollback.sh $(ENV) $(SVC)

flag: ## Set a release flag on an environment's services (ENV=… FLAG=… VALUE=true|false)
	@bash ci/flag.sh $(ENV) $(FLAG) $(VALUE)

# --- Composite ---------------------------------------------------------------

ci: ## Full local CI run (lint, env schema, types, tests, security, infra, build, boot, qa)
	@bash ci/ci.sh

clean: ## Remove build and tool caches
	@rm -rf $(VENV) .pytest_cache .ruff_cache .mypy_cache
	@find services ai -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
	@if [ -f packages/scenova_design/pubspec.yaml ]; then (cd packages/scenova_design && flutter clean) || true; fi
	@if [ -f apps/mobile/pubspec.yaml ]; then (cd apps/mobile && flutter clean) || true; fi
	@if [ -f apps/console/pubspec.yaml ]; then (cd apps/console && flutter clean) || true; fi
	@rm -rf .firebase
	@echo "cleaned"
