# Data stores (architecture.md "Data Architecture"):
#   - Cloud SQL for PostgreSQL — the primary relational store.
#   - Memorystore for Redis — rate-limit counters and hot lookup keys.
#   - Cloud Storage — clip files for the shared library and card-sized renditions.
#
# Account and entitlement data is backed up to meet a 1-hour RPO; the shared
# library is regenerable from its words and backed up to a 24-hour RPO (nfr.md).

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }
variable "network_id" { type = string }
variable "private_services_connection" { type = string }
variable "deletion_protection" { type = bool }

variable "db_tier" { type = string }
variable "db_availability" { type = string }
variable "db_disk_type" { type = string }
variable "db_disk_size_gb" { type = number }
variable "db_backup_retention_days" { type = number }
variable "db_activation_policy" { type = string }
# The teardown guard: PREVENT makes Terraform refuse to destroy the stateful
# resources, so no lifecycle action can take the data with it by accident
# (nfr.md "Privacy & Compliance" data lifecycle).
variable "data_deletion_policy" { type = string }
variable "db_name" {
  type    = string
  default = "scenova"
}
variable "db_user" {
  type    = string
  default = "scenova"
}

variable "enable_redis" { type = bool }
variable "redis_tier" { type = string }
variable "redis_memory_gb" { type = number }

variable "clip_bucket" { type = string }
variable "clip_retention_days" {
  description = "Days a superseded clip rendition is retained before deletion."
  type        = number
  default     = 30
}
variable "runtime_service_accounts" {
  description = "Runtime service accounts granted object access to the clip bucket."
  type        = list(string)
}
variable "secret_container_ids" {
  description = "Secret Manager secret ids for the generated database credential (db-password, database-url)."
  type        = map(string)
}

locals {
  labels = merge(var.labels, { environment = var.environment })
}

# --- Cloud SQL for PostgreSQL -------------------------------------------------

resource "random_password" "db" {
  length      = 32
  special     = true
  min_special = 2
  # Avoid characters that break a DSN when unescaped.
  override_special = "-_"
}

resource "google_sql_database_instance" "primary" {
  name                = "scenova-${var.environment}"
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = var.deletion_protection
  # Terraform-level teardown guard, alongside the API-level deletion_protection:
  # PREVENT fails a destroy in Terraform before it ever calls Cloud SQL, so the
  # account, entitlement, and financial data a teardown may not lose (nfr.md
  # "Privacy & Compliance") cannot be deleted by accident.
  deletion_policy = var.data_deletion_policy

  settings {
    # The shared-core tiers this shape uses (db-f1-micro in dev and pre-revenue)
    # exist only in the ENTERPRISE edition. The project's default is
    # ENTERPRISE_PLUS, which rejects them ("Invalid Tier (db-f1-micro) for
    # (ENTERPRISE_PLUS) Edition"); the custom tiers staging and prod use are valid
    # in ENTERPRISE as well, so pinning the edition keeps every environment on the
    # cheapest reachable instance.
    edition = "ENTERPRISE"

    tier              = var.db_tier
    availability_type = var.db_availability
    disk_size         = var.db_disk_size_gb
    disk_type         = var.db_disk_type
    disk_autoresize   = true
    user_labels       = local.labels
    # The API-level guard (settings.deletionProtectionEnabled): the live instance
    # refuses deletion through the API or console. The lifecycle's destroy guard
    # reads this back from the live instance before it will run (ci/lifecycle.sh),
    # so the Terraform-level `deletion_protection` alone is not enough.
    deletion_protection_enabled = var.deletion_protection
    # ALWAYS runs the instance; NEVER stops it (compute billing ends, the disk and
    # its data stay). The lifecycle's pause/destroy sets NEVER.
    activation_policy = var.db_activation_policy

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      # The API requires the transaction log retention to be no longer than the
      # backup retention, and caps it at 7 days. The free-tier shape keeps 1 day
      # of backups, so it keeps 1 day of logs; dev/staging keep 7, and prod keeps
      # the 7-day cap over its 30-day backup window.
      transaction_log_retention_days = min(var.db_backup_retention_days, 7)
      backup_retention_settings {
        retained_backups = var.db_backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    # Planned work runs in a weekly low-traffic window (nfr.md "Maintenance
    # windows"); the generation path is drained separately before the window.
    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false
    }
  }

  depends_on = [var.private_services_connection]
}

resource "google_sql_database" "primary" {
  name     = var.db_name
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
}

resource "google_sql_user" "app" {
  name     = var.db_user
  project  = var.project_id
  instance = google_sql_database_instance.primary.name
  password = random_password.db.result
}

# The generated credential is written to Secret Manager, never to the repo.
resource "google_secret_manager_secret_version" "db_password" {
  secret      = var.secret_container_ids["db-password"]
  secret_data = random_password.db.result
}

resource "google_secret_manager_secret_version" "database_url" {
  secret      = var.secret_container_ids["database-url"]
  secret_data = "postgresql+psycopg://${var.db_user}:${random_password.db.result}@${google_sql_database_instance.primary.private_ip_address}:5432/${var.db_name}"
}

# --- Memorystore for Redis ----------------------------------------------------

# Off in the free-tier shape (var.enable_redis): Memorystore has no free tier and
# a 1 GB BASIC instance bills whether or not anything reads it, so the free-tier
# shape leaves it out and the gateway uses its in-memory rate-limit counters
# (REDIS_URL empty). No other service reads Redis at boot, so the stack comes up
# without it. The production shape keeps it for the shared counters NFR-010 needs
# across replicas.
resource "google_redis_instance" "cache" {
  count = var.enable_redis ? 1 : 0

  name               = "scenova-${var.environment}"
  project            = var.project_id
  region             = var.region
  tier               = var.redis_tier
  memory_size_gb     = var.redis_memory_gb
  redis_version      = "REDIS_7_0"
  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  labels             = local.labels
  deletion_policy    = var.data_deletion_policy

  depends_on = [var.private_services_connection]
}

# --- Cloud Storage ------------------------------------------------------------

resource "google_storage_bucket" "clips" {
  name                        = var.clip_bucket
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  labels                      = local.labels
  # The bucket holds the shared library's clip files, which are kept until
  # retired (nfr.md "Privacy & Compliance"); force_destroy stays false so a
  # destroy cannot empty and delete it, and the policy is the Terraform-level
  # guard alongside it.
  deletion_policy = var.data_deletion_policy

  versioning { enabled = true }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.clip_retention_days
      num_newer_versions         = 3
    }
    action { type = "Delete" }
  }

  lifecycle_rule {
    condition {
      age = 30
      # The bucket is regional (var.region), so its objects are never
      # MULTI_REGIONAL; the GCS API refuses to create a bucket whose lifecycle
      # rule matches a class impossible for the location ("may not create
      # storageClass MULTI_REGIONAL buckets with locationConstraint ...").
      # STANDARD is the class the clips are written in.
      matches_storage_class = ["STANDARD"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
}

resource "google_storage_bucket_iam_member" "runtime_object_admin" {
  for_each = toset(var.runtime_service_accounts)
  bucket   = google_storage_bucket.clips.name
  role     = "roles/storage.objectAdmin"
  member   = "serviceAccount:${each.value}"
}
