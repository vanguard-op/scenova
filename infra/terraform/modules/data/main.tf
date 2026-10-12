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
variable "db_backup_retention_days" { type = number }
variable "db_name" {
  type    = string
  default = "scenova"
}
variable "db_user" {
  type    = string
  default = "scenova"
}

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

  settings {
    tier              = var.db_tier
    availability_type = var.db_availability
    disk_size         = 20
    disk_type         = "PD_SSD"
    disk_autoresize   = true
    user_labels       = local.labels

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = var.db_backup_retention_days
        retention_unit   = "COUNT"
      }
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

resource "google_redis_instance" "cache" {
  name               = "scenova-${var.environment}"
  project            = var.project_id
  region             = var.region
  tier               = var.redis_tier
  memory_size_gb     = var.redis_memory_gb
  redis_version      = "REDIS_7_0"
  authorized_network = var.network_id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"
  labels             = local.labels

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
      age                   = 30
      matches_storage_class = ["MULTI_REGIONAL", "STANDARD"]
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
