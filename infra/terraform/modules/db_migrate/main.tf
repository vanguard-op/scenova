# The primary database migration job (architecture.md "Data Architecture";
# release.md "Data migrations").
#
# Cloud SQL has a private-only address (modules/data), so the migrations run from
# inside the VPC: this is a Cloud Run job on the same Serverless VPC connector the
# services use, and it reads DATABASE_URL from Secret Manager (NFR-024). Terraform
# owns the job shape; the deploy pipeline owns the image tag and executes the job
# before service traffic shifts, so a schema change lands before the code that
# expects it (release.md "Data migrations").

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }
variable "connector_id" { type = string }
variable "network_id" {
  type    = string
  default = ""
}
variable "subnetwork_id" {
  type    = string
  default = ""
}
variable "vpc_egress" {
  type    = string
  default = "connector"
}
variable "service_account_email" {
  description = "Service account the job runs as; granted cloudsql.client and secretAccessor on database-url."
  type        = string
}
variable "database_url_secret" {
  description = "Secret Manager secret id holding the DATABASE_URL for this environment."
  type        = string
}
variable "image" {
  description = "Migration container image. Terraform seeds a bootstrap placeholder; the deploy pipeline replaces it."
  type        = string
}
variable "job_name" {
  type    = string
  default = "scenova-db-migrate"
}

resource "google_cloud_run_v2_job" "migrate" {
  name     = var.job_name
  project  = var.project_id
  location = var.region
  labels   = merge(var.labels, { environment = var.environment })

  # The provider default is true; the job is stateless (its image is replaced by
  # the deploy pipeline, and Terraform replaces it after a failed create), so it
  # must be destroyable.
  deletion_protection = false

  template {
    template {
      service_account = var.service_account_email
      # A failed migration is terminal and must be seen, not retried in a loop;
      # Postgres DDL is transactional, so a re-run is safe once the cause is fixed.
      max_retries = 0
      timeout     = "600s"

      vpc_access {
        egress = "PRIVATE_RANGES_ONLY"

        connector = var.vpc_egress == "connector" ? var.connector_id : null

        dynamic "network_interfaces" {
          for_each = var.vpc_egress == "direct" ? [1] : []
          content {
            network    = var.network_id
            subnetwork = var.subnetwork_id
          }
        }
      }

      containers {
        image = var.image

        env {
          name  = "ENVIRONMENT"
          value = var.environment
        }

        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = var.database_url_secret
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # The deploy pipeline owns the image; a plan must not revert a deployed tag.
    ignore_changes = [template[0].template[0].containers[0].image]
  }
}
