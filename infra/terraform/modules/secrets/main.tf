# Secret Manager (NFR-024): managed secret store, no secrets in the repository or
# logs. Terraform creates the containers and grants least-privilege access; the
# values for provider keys are written out-of-band by an operator or the deploy
# pipeline, and the generated database credential is written by the data module.
#
# Rotation: a value is replaced by adding a new version, its value piped so it is
# never printed (`gcloud secrets versions add <id> --project <p> --data-file=-`).
# A service mounts `latest` and resolves an environment-variable secret at
# instance start, so a new version reaches the running service on the next cold
# start or `make env-start` (a fresh revision). The RevenueCat webhook
# authorization is a shared password chosen in the RevenueCat dashboard: the
# seeded value must equal the dashboard's webhook Authorization header verbatim,
# or every delivery is refused (C-019).

variable "project_id" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }
variable "secret_ids" { type = list(string) }
# The teardown guard: PREVENT keeps a destroy from removing the secret containers
# (which hold the generated database credential), so a lifecycle action cannot
# strand the database by deleting the only copy of its password.
variable "deletion_policy" {
  type    = string
  default = "DELETE"
}
variable "accessors" {
  description = "Map of secret id → list of service account emails granted secretAccessor."
  type        = map(list(string))
  default     = {}
}

resource "google_secret_manager_secret" "this" {
  for_each  = toset(var.secret_ids)
  secret_id = each.value
  project   = var.project_id

  replication {
    auto {}
  }

  labels          = merge(var.labels, { environment = var.environment })
  deletion_policy = var.deletion_policy
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = {
    for pair in flatten([
      for secret_id, members in var.accessors : [
        for member in members : {
          key    = "${secret_id}__${member}"
          secret = secret_id
          member = member
        }
      ]
    ]) : pair.key => pair
    if contains(var.secret_ids, pair.secret)
  }

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.member}"
}
