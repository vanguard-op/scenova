# Per-environment configuration for Scenova (architecture.md "Deployment
# Topology", release.md "Environments & Promotion").
#
# A single root module is instantiated once per environment with the matching
# `environments/<env>.tfvars` file and a separate state (backend/<env>.hcl), so a
# change moves one environment at a time and promotion is explicit.

variable "environment" {
  description = "Environment name: dev, staging, or prod."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "project_id" {
  description = "Google Cloud project id for this environment."
  type        = string
}

variable "region" {
  description = "Single primary region for accounts, entitlements, and the shared library."
  type        = string
  default     = "us-central1"
}

variable "artifact_repo" {
  description = "Artifact Registry repository id for service container images."
  type        = string
  default     = "scenova"
}

variable "clip_bucket" {
  description = "Cloud Storage bucket holding clip files and card-sized renditions."
  type        = string
}

variable "cdn_domain" {
  description = "Custom domain for Cloud CDN. Empty disables the load balancer and serves clips from the bucket directly."
  type        = string
  default     = ""
}

variable "firebase_project_id" {
  description = "Firebase project used for Authentication (D-005)."
  type        = string
}

variable "console_site_id" {
  description = "Globally unique Firebase Hosting site id for the review console (FEAT-015)."
  type        = string
  default     = "scenova-console"
}

variable "console_review_api_base_url" {
  description = "Base URL the review console calls for the review endpoints (C-014 to C-016). Empty uses the console's own origin, which Firebase Hosting rewrites to the gateway."
  type        = string
  default     = ""
}

variable "tasks_queue" {
  description = "Cloud Tasks queue name for generation jobs."
  type        = string
  default     = "generation-jobs"
}

variable "services" {
  description = "Services to run on Cloud Run, keyed by name. `public` exposes the service to the client; every other service is internal only. Containers listen on the Cloud Run default port 8080; the per-service ports in .env apply to local development only."
  type = map(object({
    public = bool
  }))
}

variable "flags" {
  description = "Feature flags from release.md 'Rollout Phases & Feature Flags'. Runtime kill switches, owned per environment."
  type        = map(string)
}

variable "secret_ids" {
  description = "Secret Manager secret ids to create as empty containers; values are never managed by Terraform (NFR-024)."
  type        = list(string)
  default = [
    "database-url",
    "db-password",
    "gemini-api-key",
    "revenuecat-api-key",
    "revenuecat-webhook-auth",
  ]
}

variable "internal_audience" {
  description = "Audience asserted on internal service-to-service calls (C-003, C-004, C-005)."
  type        = string
  default     = "scenova-internal"
}

variable "db_tier" {
  description = "Cloud SQL machine tier."
  type        = string
  default     = "db-f1-micro"
}

variable "db_availability" {
  description = "Cloud SQL availability type: ZONAL or REGIONAL. Production uses REGIONAL."
  type        = string
  default     = "ZONAL"
}

variable "db_backup_retention_days" {
  description = "Cloud SQL automated backup retention, meeting the 1-hour RPO for account and entitlement data."
  type        = number
  default     = 7
}

variable "redis_tier" {
  description = "Memorystore tier: BASIC or STANDARD_HA."
  type        = string
  default     = "BASIC"
}

variable "redis_memory_gb" {
  description = "Memorystore Redis capacity in GB."
  type        = number
  default     = 1
}

variable "deletion_protection" {
  description = "Guard against accidental destruction of stateful resources. On in production."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Notification channel email for availability alerts. Empty skips alert policies."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels applied to resources."
  type        = map(string)
  default     = {}
}
