# Per-environment configuration for Scenova (architecture.md "Deployment
# Topology", release.md "Environments & Promotion").
#
# A single root module is instantiated once per environment with the matching
# `environments/<env>.tfvars` file and a separate state (backend/<env>.hcl), so a
# change moves one environment at a time and promotion is explicit.

variable "environment" {
  description = "Environment name: dev, staging, prod, or pre-revenue (D-034: the free-tier shape that runs before there are readers)."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod", "pre-revenue"], var.environment)
    error_message = "environment must be one of: dev, staging, prod, pre-revenue."
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

variable "identity_gcip" {
  description = "The project is on Identity Platform (GCIP), enabling the MFA gate (NFR-020) and auth activity logging (NFR-029). On for the production shape; off for the pre-revenue Firebase free-tier shape (D-034)."
  type        = bool
  default     = true
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

# The lifecycle's runtime switch. Off removes the Cloud Run services and the
# uptime check from the environment (the data stores, network, and secrets stay),
# so the paid runtime exists only during a testing window; on recreates them.
# Everything the runtime does is scale-to-zero, so this is about removing the
# surface, not about an idle bill — the idle bill is Cloud SQL, which
# db_activation_policy stops.
variable "runtime_enabled" {
  description = "Run the Cloud Run services and their uptime check. Off tears the runtime down while keeping the data stores."
  type        = bool
  default     = true
}

# The production shape keeps one warm gateway instance so the first reader after
# an idle period is not cold-started. The free-tier shape runs no min instances
# at all: an idle min instance is billed at Cloud Run's idle rate even with no
# traffic (cloud.google.com/run/pricing), so it sets this to 0 and accepts a cold
# start — the availability NFR-010 asks for is not bought before there are
# readers (D-034).
variable "gateway_min_instances" {
  description = "Minimum Cloud Run instances for the gateway. 0 is scale-to-zero."
  type        = number
  default     = 1
}

# How Cloud Run reaches the private VPC (Cloud SQL). "connector" uses a
# Serverless VPC Access connector, which bills at least two Compute Engine
# instances 24/7; "direct" uses Direct VPC egress, which needs no connector and
# no always-on resource (cloud.google.com/run/docs/configuring/vpc-direct-vpc).
# The production shape keeps the connector; the free-tier shape uses direct.
variable "vpc_egress" {
  description = "Cloud Run VPC egress: connector (Serverless VPC Access, always-on) or direct (Direct VPC egress, no connector)."
  type        = string
  default     = "connector"

  validation {
    condition     = contains(["connector", "direct"], var.vpc_egress)
    error_message = "vpc_egress must be connector or direct."
  }
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

# The provider credentials (Gemini, RevenueCat) are written out-of-band, so their
# containers may have no version when the runtime first starts; Cloud Run refuses
# to mount a versionless secret. The provider-backed features (generation, the
# paid tier) are off in the free-tier shape, so it leaves these mounts off and the
# services read them as optional; the production shape mounts them and its
# operator seeds the values.
variable "mount_provider_secrets" {
  description = "Mount the Gemini and RevenueCat provider credentials on the model and entitlement services. Off in the free-tier shape, where generation and the paid tier are off and their values are not yet seeded."
  type        = bool
  default     = true
}

variable "internal_audience" {
  description = "Audience asserted on internal service-to-service calls (C-003, C-004, C-005)."
  type        = string
  default     = "scenova-internal"
}

variable "db_tier" {
  description = "Cloud SQL machine tier. db-f1-micro (shared core, 0.6 GB) is the cheapest reachable PostgreSQL."
  type        = string
  default     = "db-f1-micro"
}

variable "db_availability" {
  description = "Cloud SQL availability type: ZONAL or REGIONAL. Production uses REGIONAL."
  type        = string
  default     = "ZONAL"
}

variable "db_disk_type" {
  description = "Cloud SQL data disk type: PD_SSD, PD_HDD, or HYPERDISK_BALANCED. PD_HDD is the cheapest."
  type        = string
  default     = "PD_SSD"
}

variable "db_disk_size_gb" {
  description = "Cloud SQL data disk size in GB (minimum 10)."
  type        = number
  default     = 20
}

variable "db_backup_retention_days" {
  description = "Cloud SQL automated backup retention, meeting the 1-hour RPO for account and entitlement data."
  type        = number
  default     = 7
}

# The database is the only always-on paid resource in the free-tier shape, so the
# lifecycle's pause/destroy stops it rather than deleting it: NEVER stops the
# instance (compute billing ends, the disk and its data stay), ALWAYS resumes it.
variable "db_activation_policy" {
  description = "Cloud SQL activation policy: ALWAYS (running) or NEVER (stopped, data retained)."
  type        = string
  default     = "ALWAYS"

  validation {
    condition     = contains(["ALWAYS", "NEVER"], var.db_activation_policy)
    error_message = "db_activation_policy must be ALWAYS or NEVER."
  }
}

# The teardown guard (nfr.md "Privacy & Compliance" data lifecycle): account and
# entitlement data lives for the life of the account, financial records for seven
# years, and shared library entries until retired, so no lifecycle action may
# delete the data stores. PREVENT makes Terraform refuse a destroy of the stateful
# resources outright; the free-tier shape sets it, dev/staging/prod leave DELETE.
variable "data_deletion_policy" {
  description = "Terraform deletion policy for stateful resources (Cloud SQL, the clip bucket, secrets): DELETE, PREVENT, or ABANDON."
  type        = string
  default     = "DELETE"

  validation {
    condition     = contains(["DELETE", "PREVENT", "ABANDON"], var.data_deletion_policy)
    error_message = "data_deletion_policy must be DELETE, PREVENT, or ABANDON."
  }
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

# Memorystore has no free tier (a 1 GB BASIC instance bills ~$35/month whether or
# not anything reads it), so the free-tier shape leaves it out and the gateway
# falls back to its in-memory rate-limit counters (REDIS_URL empty; see
# services/gateway/app/ratelimit.py). Nothing else consumes Redis at boot.
variable "enable_redis" {
  description = "Create Memorystore for Redis. Off in the free-tier shape, where nothing may bill while idle."
  type        = bool
  default     = true
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
