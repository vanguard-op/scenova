# Artifact Registry and Cloud Run services (architecture.md "Deployment
# Topology"; release.md canary for services).
#
# The gateway is the single public entry point; every other service is internal
# only (INGRESS_TRAFFIC_INTERNAL_ONLY) and reachable only by an authenticated
# service identity (C-003, C-004, C-005). Terraform owns the service shape,
# environment, and secret wiring; the deploy pipeline owns the image tag, which is
# left untouched here so a canary roll-out is not reverted on the next plan.

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }
variable "artifact_repo" { type = string }
variable "connector_id" { type = string }

variable "services" {
  description = "Cloud Run services keyed by name. Containers listen on the Cloud Run default port 8080."
  type = map(object({
    public                = bool
    service_account_email = string
    image                 = string
    env                   = map(string)
    secret_env            = map(string)
    cpu                   = optional(string, "1")
    memory                = optional(string, "512Mi")
    min_instances         = optional(number, 0)
    max_instances         = optional(number, 10)
    concurrency           = optional(number, 80)
  }))
}

variable "internal_invokers" {
  description = "Service account emails allowed to call the internal services."
  type        = list(string)
}

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repo
  format        = "DOCKER"
  description   = "Scenova service and model container images"
  labels        = var.labels

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions { keep_count = 10 }
  }
}

resource "google_cloud_run_v2_service" "this" {
  for_each = var.services

  name     = each.key
  project  = var.project_id
  location = var.region
  ingress  = each.value.public ? "INGRESS_TRAFFIC_ALL" : "INGRESS_TRAFFIC_INTERNAL_ONLY"
  labels   = merge(var.labels, { environment = var.environment })

  template {
    service_account                  = each.value.service_account_email
    max_instance_request_concurrency = each.value.concurrency

    scaling {
      min_instance_count = each.value.min_instances
      max_instance_count = each.value.max_instances
    }

    vpc_access {
      connector = var.connector_id
      egress    = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = each.value.image

      ports {
        # Cloud Run convention: the container listens on 8080 (PORT).
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = each.value.cpu
          memory = each.value.memory
        }
      }

      dynamic "env" {
        for_each = each.value.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = each.value.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # The deploy pipeline owns the image; a plan must not revert a canary.
    ignore_changes = [template[0].containers[0].image]
  }
}

# Public invoker for the gateway only.
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = { for name, svc in var.services : name => svc if svc.public }

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.this[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Authenticated service-to-service invocation of the internal services.
resource "google_cloud_run_v2_service_iam_member" "internal" {
  for_each = {
    for pair in setproduct(
      [for name, svc in var.services : name if !svc.public],
      var.internal_invokers
    ) : "${pair[0]}__${pair[1]}" => { service = pair[0], member = pair[1] }
  }

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.this[each.value.service].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${each.value.member}"
}
