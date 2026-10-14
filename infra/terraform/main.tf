# Scenova infrastructure — one root module, instantiated once per environment
# (dev / staging / prod) with environments/<env>.tfvars and a separate state
# (backend/<env>.hcl). Covers architecture.md "Deployment Topology", "External
# Integrations", and "Data Architecture"; release.md "Environments & Promotion";
# and the security controls in nfr.md NFR-020 to NFR-029.

# --- Identity: one runtime service account per service (least privilege) ------

resource "google_service_account" "runtime" {
  for_each = var.services

  project      = var.project_id
  account_id   = "scenova-${each.key}"
  display_name = "Scenova ${each.key} runtime (${var.environment})"
}

resource "google_service_account" "tasks" {
  project      = var.project_id
  account_id   = "scenova-tasks"
  display_name = "Scenova generation queue invoker (${var.environment})"
}

resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = "scenova-deploy"
  display_name = "Scenova deploy pipeline (${var.environment})"
}

locals {
  runtime_emails     = { for k, sa in google_service_account.runtime : k => sa.email }
  all_runtime_emails = values(local.runtime_emails)
}

# --- Network ------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = var.labels
}

# --- Secrets (containers only; values live in Secret Manager) -----------------

module "secrets" {
  source = "./modules/secrets"

  project_id  = var.project_id
  environment = var.environment
  labels      = var.labels
  secret_ids  = var.secret_ids

  accessors = {
    "database-url"            = local.all_runtime_emails
    "db-password"             = local.all_runtime_emails
    "gemini-api-key"          = [local.runtime_emails["model"]]
    "revenuecat-api-key"      = [local.runtime_emails["entitlement"]]
    "revenuecat-webhook-auth" = [local.runtime_emails["entitlement"]]
  }
}

# --- Data stores --------------------------------------------------------------

module "data" {
  source = "./modules/data"

  project_id                  = var.project_id
  region                      = var.region
  environment                 = var.environment
  labels                      = var.labels
  network_id                  = module.network.vpc_id
  private_services_connection = module.network.private_services_connection
  deletion_protection         = var.deletion_protection

  db_tier                  = var.db_tier
  db_availability          = var.db_availability
  db_backup_retention_days = var.db_backup_retention_days

  redis_tier      = var.redis_tier
  redis_memory_gb = var.redis_memory_gb

  clip_bucket = var.clip_bucket

  runtime_service_accounts = [
    local.runtime_emails["pipeline"],
    local.runtime_emails["library"],
    local.runtime_emails["model"],
  ]

  secret_container_ids = module.secrets.secret_ids
}

# --- Queue --------------------------------------------------------------------

module "queue" {
  source = "./modules/queue"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  queue_name  = var.tasks_queue
}

# --- CDN (optional per environment) -------------------------------------------

module "cdn" {
  count  = var.cdn_domain == "" ? 0 : 1
  source = "./modules/cdn"

  project_id  = var.project_id
  bucket_name = module.data.bucket_name
  cdn_domain  = var.cdn_domain
  labels      = var.labels
}

# --- Runtime configuration shared by every service ---------------------------

locals {
  cdn_base_url = var.cdn_domain == "" ? "" : "https://${var.cdn_domain}"

  # The two model pins the generation path uses and no others (architecture
  # "Model Version & Fallback"): the text model for the gloss phrase and the
  # video model for the clip. Product-wide constants, so they are the same in
  # every environment; an upgrade is a new pin after a fresh evaluation.
  common_env = {
    ENVIRONMENT                   = var.environment
    GCP_PROJECT_ID                = var.project_id
    GCP_REGION                    = var.region
    CLIP_BUCKET                   = module.data.bucket_name
    CLIP_CDN_BASE_URL             = local.cdn_base_url
    PHRASE_MODEL_PIN              = "gemini-3.5-flash-lite"
    CLIP_MODEL_PIN                = "gemini-omni-1.1-flash"
    PHRASE_MODEL_PINNED_AT        = "2026-10-12T00:00:00+00:00"
    CLIP_MODEL_PINNED_AT          = "2026-10-12T00:00:00+00:00"
    INTERNAL_AUDIENCE             = var.internal_audience
    TASKS_PROJECT                 = var.project_id
    TASKS_LOCATION                = var.region
    TASKS_QUEUE                   = module.queue.queue_name
    TASKS_INVOKER_SERVICE_ACCOUNT = google_service_account.tasks.email
    REDIS_URL                     = "redis://${module.data.redis_host}:${module.data.redis_port}/0"
    FIREBASE_PROJECT_ID           = var.firebase_project_id
    LOG_LEVEL                     = var.environment == "prod" ? "info" : "debug"
  }

  service_extra_env = {
    # The notification service is the only sender to the push notification
    # service (architecture.md "External Integrations": push, outbound, medium
    # criticality, FEAT-008). The provider is Firebase Cloud Messaging, the
    # Google-managed push service behind the Firebase project the client already
    # uses for identity (D-005); the send endpoint is a product-wide constant and
    # the project id is shared as FIREBASE_PROJECT_ID (common_env). No credential
    # is carried in the environment: the send is authorized by a short-lived
    # OAuth 2.0 token minted from the runtime service account through ADC, so
    # there is no static secret to store or rotate (NFR-024).
    notification = {
      PUSH_PROVIDER     = "firebase"
      PUSH_FCM_BASE_URL = "https://fcm.googleapis.com"
    }
    model = {
      GEMINI_TIMEOUT_SECONDS            = "30"
      GEMINI_MAX_ATTEMPTS               = "3"
      CIRCUIT_BREAKER_FAILURE_THRESHOLD = "5"
      CIRCUIT_BREAKER_RESET_SECONDS     = "60"
    }
  }

  service_secret_env = {
    gateway  = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    lookup   = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    pipeline = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    library  = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    feedback = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    # Push registrations attach the reader's token to a lookup (C-008), which the
    # notification service reads back when that lookup's generation completes.
    notification = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    entitlement = {
      DATABASE_URL            = module.secrets.secret_ids["database-url"]
      REVENUECAT_API_KEY      = module.secrets.secret_ids["revenuecat-api-key"]
      REVENUECAT_WEBHOOK_AUTH = module.secrets.secret_ids["revenuecat-webhook-auth"]
    }
    model = { GEMINI_API_KEY = module.secrets.secret_ids["gemini-api-key"] }
  }

  # Bootstrap placeholder so the first apply never depends on a pushed image; the
  # deploy pipeline replaces it (the run module ignores image drift).
  bootstrap_image = "us-docker.pkg.dev/cloudrun/container/hello:latest"
}

# --- Cloud Run services -------------------------------------------------------

module "run" {
  source = "./modules/run"

  project_id    = var.project_id
  region        = var.region
  environment   = var.environment
  labels        = var.labels
  artifact_repo = var.artifact_repo
  connector_id  = module.network.connector_id

  internal_invokers = concat(local.all_runtime_emails, [google_service_account.tasks.email])

  services = {
    for name, cfg in var.services : name => {
      public                = cfg.public
      service_account_email = local.runtime_emails[name]
      image                 = local.bootstrap_image
      env                   = merge(local.common_env, var.flags, lookup(local.service_extra_env, name, {}))
      secret_env            = lookup(local.service_secret_env, name, {})
      min_instances         = name == "gateway" ? 1 : 0
      max_instances         = 10
    }
  }
}

# --- IAM: least privilege for the runtime -------------------------------------

resource "google_project_iam_member" "runtime_cloudsql" {
  for_each = google_service_account.runtime

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${each.value.email}"
}

resource "google_project_iam_member" "pipeline_tasks_enqueuer" {
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  member  = "serviceAccount:${local.runtime_emails["pipeline"]}"
}

# The pipeline creates OIDC tokens for the tasks service account when enqueuing.
resource "google_service_account_iam_member" "pipeline_act_as_tasks" {
  service_account_id = google_service_account.tasks.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.runtime_emails["pipeline"]}"
}

# The notification service is the only principal allowed to send to the push
# notification service (architecture.md "External Integrations"). Firebase Cloud
# Messaging authorizes a send with a short-lived OAuth 2.0 token from the runtime
# service account, so no static credential is issued (NFR-024);
# `roles/firebasecloudmessaging.admin` is the predefined role carrying the send
# permission `cloudmessaging.messages.create` and is granted to no other service.
resource "google_project_iam_member" "notification_push_sender" {
  project = var.project_id
  role    = "roles/firebasecloudmessaging.admin"
  member  = "serviceAccount:${local.runtime_emails["notification"]}"
}

# --- Audit logging (NFR-029) --------------------------------------------------

resource "google_project_iam_audit_config" "secretmanager" {
  project = var.project_id
  service = "secretmanager.googleapis.com"

  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_READ" }
}

resource "google_project_iam_audit_config" "iam" {
  project = var.project_id
  service = "iam.googleapis.com"

  audit_log_config { log_type = "ADMIN_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}

# --- Review console (FEAT-015) ------------------------------------------------

# The operator-only console is a static Flutter Web app on its own Firebase
# Hosting site. It gets no Cloud Run service and no runtime service account: it
# holds no Google Cloud identity and no secret, and its access is gated by the
# curator role and MFA at sign-in, not by a network boundary.
module "console" {
  source = "./modules/console"

  providers = {
    google-beta = google-beta
  }

  project_id  = var.firebase_project_id
  environment = var.environment
  site_id     = var.console_site_id
}

# --- Identity: the curator role's multi-factor gate (NFR-020) ------------------

module "identity" {
  source = "./modules/identity"

  project_id = var.firebase_project_id

  # The console signs in through OAuth redirects, so its Hosting domains and
  # localhost are authorized; the project's own Firebase domains are implied by
  # the provider but listed for clarity.
  authorized_domains = [
    "localhost",
    "${var.firebase_project_id}.firebaseapp.com",
    "${var.firebase_project_id}.web.app",
    replace(module.console.default_url, "https://", ""),
  ]
}

# --- Monitoring ---------------------------------------------------------------

module "monitoring" {
  source = "./modules/monitoring"

  project_id  = var.project_id
  environment = var.environment
  gateway_url = module.run.service_uris["gateway"]
  alert_email = var.alert_email
}
