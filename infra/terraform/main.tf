# Scenova infrastructure — one root module, instantiated once per environment
# (dev / staging / prod) with environments/<env>.tfvars and a separate state
# (backend/<env>.hcl). Covers architecture.md "Deployment Topology", "External
# Integrations", and "Data Architecture"; release.md "Environments & Promotion";
# and the security controls in nfr.md NFR-020 to NFR-029.

# --- Identity: one runtime service account per service (least privilege) ------

# The service-account ids and their emails are derived from the service map's
# keys, which are known at plan time, so every `for_each` built from them is
# known before apply. Reading the email off the created resource instead
# (`sa.email`) would make those `for_each` values apply-time-only, which
# `terraform import` rejects — and the resources that already exist on the
# project must be imported before the first apply (ci/bootstrap.sh). The
# account-id format lives here once, so an id and its email cannot drift.
locals {
  runtime_account_ids = { for name in keys(var.services) : name => "scenova-${name}" }
  runtime_emails      = { for name, id in local.runtime_account_ids : name => "${id}@${var.project_id}.iam.gserviceaccount.com" }
  all_runtime_emails  = values(local.runtime_emails)

  tasks_account_id   = "scenova-tasks"
  tasks_email        = "${local.tasks_account_id}@${var.project_id}.iam.gserviceaccount.com"
  deploy_account_id  = "scenova-deploy"
  deploy_email       = "${local.deploy_account_id}@${var.project_id}.iam.gserviceaccount.com"
  migrate_account_id = "scenova-migrate"
  migrate_email      = "${local.migrate_account_id}@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_service_account" "runtime" {
  for_each = local.runtime_account_ids

  project      = var.project_id
  account_id   = each.value
  display_name = "Scenova ${each.key} runtime (${var.environment})"
}

resource "google_service_account" "tasks" {
  project      = var.project_id
  account_id   = local.tasks_account_id
  display_name = "Scenova generation queue invoker (${var.environment})"
}

resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = local.deploy_account_id
  display_name = "Scenova deploy pipeline (${var.environment})"
}

# The migration job's identity: it reads DATABASE_URL and reaches Cloud SQL over
# the VPC connector, and it can do nothing else (least privilege, NFR-020).
resource "google_service_account" "migrate" {
  project      = var.project_id
  account_id   = local.migrate_account_id
  display_name = "Scenova database migration job (${var.environment})"
}

# --- Network ------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  project_id  = var.project_id
  region      = var.region
  environment = var.environment
  labels      = var.labels
  vpc_egress  = var.vpc_egress
}

# --- Secrets (containers only; values live in Secret Manager) -----------------

module "secrets" {
  source = "./modules/secrets"

  project_id      = var.project_id
  environment     = var.environment
  labels          = var.labels
  secret_ids      = var.secret_ids
  deletion_policy = var.data_deletion_policy

  accessors = {
    "database-url"            = concat(local.all_runtime_emails, [local.migrate_email])
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
  db_disk_type             = var.db_disk_type
  db_disk_size_gb          = var.db_disk_size_gb
  db_backup_retention_days = var.db_backup_retention_days
  db_activation_policy     = var.db_activation_policy
  data_deletion_policy     = var.data_deletion_policy

  enable_redis    = var.enable_redis
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

# --- Primary database migrations (FEAT-006, FEAT-010, FEAT-011, FEAT-013) ------

# The migration job applies the revisions under infra/db/migrations against Cloud
# SQL from inside the VPC; `make deploy` runs it before service traffic shifts,
# and `make db-migrate-cloud ENV=…` runs it on its own.
module "db_migrate" {
  source = "./modules/db_migrate"

  project_id            = var.project_id
  region                = var.region
  environment           = var.environment
  labels                = var.labels
  connector_id          = module.network.connector_id
  network_id            = module.network.vpc_id
  subnetwork_id         = module.network.subnet_id
  vpc_egress            = var.vpc_egress
  service_account_email = local.migrate_email
  database_url_secret   = module.secrets.secret_ids["database-url"]
  image                 = local.bootstrap_image

  # The job mounts DATABASE_URL from Secret Manager, whose version is written by
  # the data module once the instance exists. The secret id alone is a static
  # string, so without this the job could be created before the version it
  # references and Cloud Run rejects it ("Secret .../database-url/versions/latest
  # was not found").
  depends_on = [module.data]
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
    TASKS_INVOKER_SERVICE_ACCOUNT = local.tasks_email
    # Empty when Redis is not part of the shape (var.enable_redis): the gateway
    # reads an empty REDIS_URL as "no shared cache" and serves rate limits from
    # its in-memory counters (services/gateway/app/ratelimit.py), so the stack
    # boots with no Redis in the path.
    REDIS_URL           = var.enable_redis ? "redis://${module.data.redis_host}:${module.data.redis_port}/0" : ""
    FIREBASE_PROJECT_ID = var.firebase_project_id
    LOG_LEVEL           = var.environment == "prod" ? "info" : "debug"
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
    # The entitlement service meters a lookup against the reader's tier and
    # applies a store purchase (C-018, C-019, FEAT-013). It reads what each tier
    # grants (monetization.md "Pricing Tiers") from the environment, so a pricing
    # change is a configuration change and not a code change; the values are
    # declared once in `.env.example` and held in step by `make env`. The
    # RevenueCat secrets are mounted separately (service_secret_env).
    entitlement = {
      ENTITLEMENT_FREE_LOOKUPS  = "20"
      ENTITLEMENT_PRO_LOOKUPS   = "50"
      ENTITLEMENT_TOPUP_LOOKUPS = "20"
      ENTITLEMENT_TRIAL_DAYS    = "7"
    }
  }

  # The provider credentials (Gemini, RevenueCat) are mounted only where the
  # provider-backed feature is on (var.mount_gemini_secret,
  # var.mount_revenuecat_api_key, var.mount_revenuecat_webhook_auth). Their values
  # are written out-of-band and never by Terraform (variables.tf "secret_ids",
  # NFR-024), so a secret container with no version yet — which Cloud Run refuses
  # to mount ("Secret .../versions/latest was not found") — would otherwise stop
  # the runtime from starting. The mounts are split per credential so a seeded
  # credential can go live on its service as soon as it is written, while one that
  # has no value yet stays unmounted; an unmounted secret is read as optional
  # (ai/app/config.py, services/entitlement/app/config.py). The generated database
  # credential is always mounted; Terraform writes its version (modules/data), so
  # module.run depends on module.data to order the apply.
  service_secret_env = {
    gateway  = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    lookup   = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    pipeline = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    library  = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    feedback = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    # Push registrations attach the reader's token to a lookup (C-008), which the
    # notification service reads back when that lookup's generation completes.
    notification = { DATABASE_URL = module.secrets.secret_ids["database-url"] }
    entitlement = merge(
      { DATABASE_URL = module.secrets.secret_ids["database-url"] },
      var.mount_revenuecat_api_key ? {
        REVENUECAT_API_KEY = module.secrets.secret_ids["revenuecat-api-key"]
      } : {},
      var.mount_revenuecat_webhook_auth ? {
        REVENUECAT_WEBHOOK_AUTH = module.secrets.secret_ids["revenuecat-webhook-auth"]
      } : {}
    )
    model = var.mount_gemini_secret ? { GEMINI_API_KEY = module.secrets.secret_ids["gemini-api-key"] } : {}
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
  network_id    = module.network.vpc_id
  subnetwork_id = module.network.subnet_id
  vpc_egress    = var.vpc_egress
  enabled       = var.runtime_enabled

  internal_invokers = concat(local.all_runtime_emails, [local.tasks_email])

  services = {
    for name, cfg in var.services : name => {
      public                = cfg.public
      service_account_email = local.runtime_emails[name]
      image                 = local.bootstrap_image
      env                   = merge(local.common_env, var.flags, lookup(local.service_extra_env, name, {}))
      secret_env            = lookup(local.service_secret_env, name, {})
      min_instances         = name == "gateway" ? var.gateway_min_instances : 0
      max_instances         = 10
    }
  }

  # The services mount DATABASE_URL, whose Secret Manager version the data module
  # writes once the instance exists; the secret id is a static string, so without
  # this a service could be created before the version it mounts (Cloud Run:
  # "Secret .../database-url/versions/latest was not found").
  depends_on = [module.data]
}

# --- IAM: least privilege for the runtime -------------------------------------

resource "google_project_iam_member" "runtime_cloudsql" {
  # Keys come from the static account-id map, not the created resource, so the
  # instances are known before apply (a `terraform import` requirement).
  for_each = local.runtime_account_ids

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${local.runtime_emails[each.key]}"
}

# The migration job reaches Cloud SQL over the VPC connector and nothing else.
resource "google_project_iam_member" "migrate_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${local.migrate_email}"
}

# The deploy pipeline runs the migration job as the migrate identity, so
# `gcloud run jobs execute` (from `make deploy` / `make db-migrate-cloud`) works
# without a separate grant.
resource "google_service_account_iam_member" "deploy_act_as_migrate" {
  service_account_id = google_service_account.migrate.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.deploy_email}"
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
  # The adopted Firebase Hosting site and Web App carry the same teardown guard
  # as the data stores: PREVENT in the pre-revenue shape, so a stray
  # `terraform destroy` cannot take the console's hosting (nfr.md "Privacy &
  # Compliance").
  deletion_policy = var.data_deletion_policy
}

# --- Identity: the curator role's multi-factor gate (NFR-020) ------------------

module "identity" {
  source = "./modules/identity"

  project_id = var.firebase_project_id

  # The MFA gate and auth activity logging need the Identity Platform (GCIP)
  # upgrade the free-tier pre-revenue shape does not take (D-034); the production
  # shape turns them on by configuration.
  gcip = var.identity_gcip

  # The console signs in through OAuth redirects, so its Hosting domains and
  # localhost are authorized; the project's own Firebase domains are implied by
  # the provider but listed for clarity. `distinct` drops the console's own
  # Hosting domain when it is already one of the project's `.web.app` domains —
  # Identity Platform returns a de-duplicated list, so a repeated entry would
  # otherwise show as a diff on every plan.
  authorized_domains = distinct([
    "localhost",
    "${var.firebase_project_id}.firebaseapp.com",
    "${var.firebase_project_id}.web.app",
    replace(module.console.default_url, "https://", ""),
  ])
}

# --- Monitoring ---------------------------------------------------------------

module "monitoring" {
  source = "./modules/monitoring"

  project_id  = var.project_id
  environment = var.environment
  # Empty when the runtime is torn down: no gateway to probe.
  gateway_url = try(module.run.service_uris["gateway"], "")
  alert_email = var.alert_email
  enabled     = var.runtime_enabled
}
