# Artifact Registry and Cloud Run services (architecture.md "Deployment
# Topology"; release.md canary for services).
#
# The gateway is the single public entry point; every other service is internal
# only (INGRESS_TRAFFIC_INTERNAL_ONLY) and reachable only by an authenticated
# service identity (C-003, C-004, C-005). Terraform owns the service shape,
# environment, and secret wiring — including each service's `<NAME>_BASE_URL` for
# the internal services it calls and the egress that lets it reach them — and the
# deploy pipeline owns the image tag, which is left untouched here so a canary
# roll-out is not reverted on the next plan.

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }
variable "artifact_repo" { type = string }
variable "connector_id" { type = string }
# Direct VPC egress target, used when vpc_egress = "direct" (no connector).
variable "network_id" {
  type    = string
  default = ""
}
variable "subnetwork_id" {
  type    = string
  default = ""
}
# "connector" attaches the Serverless VPC Access connector; "direct" uses Direct
# VPC egress, which needs no always-on connector.
variable "vpc_egress" {
  type    = string
  default = "connector"
}
# The lifecycle's runtime switch: off removes every Cloud Run service (and the
# environment's runtime surface) while leaving the data stores, network, and
# secrets untouched. Artifact Registry is kept either way — it is free up to
# 0.5 GB and holds the images a later start would deploy.
variable "enabled" {
  type    = bool
  default = true
}

variable "services" {
  description = "Cloud Run services keyed by name. Containers listen on the Cloud Run default port 8080."
  type = map(object({
    public                = bool
    service_account_email = string
    image                 = string
    env                   = map(string)
    secret_env            = map(string)
    # The internal services this service calls over their default `run.app` URLs.
    # Each name becomes `<NAME>_BASE_URL` in this service's environment, valued
    # from `downstream_uris` (see the resource below), so the platform owns the
    # internal wiring and a plan cannot revert a value set by hand.
    downstream    = optional(list(string), [])
    cpu           = optional(string, "1")
    memory        = optional(string, "512Mi")
    min_instances = optional(number, 0)
    max_instances = optional(number, 10)
    concurrency   = optional(number, 80)
  }))
}

variable "internal_invokers" {
  description = "Service account emails allowed to call the internal services."
  type        = list(string)
}

# The base URIs of the services a service calls, keyed by service name. Terraform
# refuses a resource that refers to itself, so a service cannot take a callee's
# URI from the callee's resource when both are created by the same block; and the
# internal call graph is not a strict order (lookup → pipeline → notification →
# lookup), so no ordering of blocks can resolve it either. The caller passes the
# deterministic Cloud Run URL for each service here instead — predictable before
# the service exists — and the module resolves each name in a service's
# `downstream` list into `<NAME>_BASE_URL`.
variable "downstream_uris" {
  description = "Downstream service base URIs keyed by service name, resolved into <NAME>_BASE_URL for a service that names them in `downstream`."
  type        = map(string)
  default     = {}
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
  for_each = var.enabled ? var.services : {}

  name     = each.key
  project  = var.project_id
  location = var.region
  ingress  = each.value.public ? "INGRESS_TRAFFIC_ALL" : "INGRESS_TRAFFIC_INTERNAL_ONLY"
  labels   = merge(var.labels, { environment = var.environment })

  # The provider default is true, which would stop the lifecycle's `destroy` from
  # removing the runtime surface (var.enabled = false). The teardown guards belong
  # on the data stores, not on a stateless, recreatable service.
  deletion_protection = false

  template {
    service_account                  = each.value.service_account_email
    max_instance_request_concurrency = each.value.concurrency

    scaling {
      min_instance_count = each.value.min_instances
      max_instance_count = each.value.max_instances
    }

    # The private VPC (Cloud SQL) is reached either through the Serverless VPC
    # Access connector or, in direct mode, through Direct VPC egress on this
    # service's own network interface — no connector, no always-on resource.
    #
    # A service that calls another internal service over its `run.app` URL must
    # route all egress through the VPC. With `PRIVATE_RANGES_ONLY` the call
    # leaves for the internet, and Cloud Run's internal ingress refuses it
    # because the source is not the VPC
    # (docs.cloud.google.com/run/docs/securing/private-networking); `ALL_TRAFFIC`
    # keeps the call on the VPC, where the subnet's Private Google Access still
    # carries the Google APIs a service needs (Firebase signing certs, FCM, the
    # model provider). A service with no internal downstream keeps
    # `PRIVATE_RANGES_ONLY`, so a non-Google call — the payment processor's API —
    # leaves directly instead of needing a Cloud NAT.
    vpc_access {
      egress = length(each.value.downstream) > 0 ? "ALL_TRAFFIC" : "PRIVATE_RANGES_ONLY"

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

      # The service's own environment, plus a `<NAME>_BASE_URL` for every
      # downstream service, valued from the `downstream_uris` map the caller
      # passes in (the deterministic Cloud Run URL of each service).
      dynamic "env" {
        for_each = merge(
          each.value.env,
          {
            for dep in each.value.downstream :
            "${upper(dep)}_BASE_URL" => var.downstream_uris[dep]
          }
        )
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

# Public invoker for the gateway only. The instance keys come from the static
# service map (not the created resource), so they are known before apply — a
# `terraform import` requirement; the resource body reads the created service.
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = var.enabled ? { for name, svc in var.services : name => svc if svc.public } : {}

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.this[each.key].name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Authenticated service-to-service invocation of the internal services. Built
# from the static service map, so a torn-down runtime has no IAM bindings
# pointing at a service that is gone and the keys are known before apply.
resource "google_cloud_run_v2_service_iam_member" "internal" {
  for_each = var.enabled ? {
    for pair in setproduct(
      [for name, svc in var.services : name if !svc.public],
      var.internal_invokers
    ) : "${pair[0]}__${pair[1]}" => { service = pair[0], member = pair[1] }
  } : {}

  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.this[each.value.service].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${each.value.member}"
}
