# The review console's environment (FEAT-015; architecture.md "Review Console").
#
# The console is a Flutter Web application served from its own Firebase Hosting
# site on the same Firebase project as the reader client, so its ID tokens are
# verified by the services against the project they already trust. It holds no
# Google Cloud runtime identity and no secret: a static operator surface has
# nothing to hold (least privilege, NFR-020; NFR-024). The site is linked to a
# dedicated Web App, which is what lets Hosting serve the Firebase client config
# at `/__/firebase/init.json` at runtime.

terraform {
  required_providers {
    # Firebase Hosting and Firebase Web App resources are beta-only.
    google-beta = {
      source = "hashicorp/google-beta"
    }
  }
}

variable "project_id" {
  description = "Firebase project the console authenticates against."
  type        = string
}

variable "environment" { type = string }

variable "site_id" {
  description = "Globally unique Firebase Hosting site id for the console."
  type        = string
}

# The teardown guard, alongside the data stores (nfr.md "Privacy & Compliance").
# On an already-initialised project the site and its Web App are adopted with
# `terraform import`; once adopted they are Terraform-managed, so a stray
# `terraform destroy` would remove the console's hosting. PREVENT makes that
# destroy fail in Terraform, the same guard the stateful resources carry.
variable "deletion_policy" {
  description = "Terraform deletion policy for the adopted Firebase resources: DELETE, PREVENT, or ABANDON."
  type        = string
  default     = "DELETE"

  validation {
    condition     = contains(["DELETE", "PREVENT", "ABANDON"], var.deletion_policy)
    error_message = "deletion_policy must be DELETE, PREVENT, or ABANDON."
  }
}

# The console's Web App, distinct from the reader client's: it is the identity
# Hosting links to the site and the source of the runtime client config.
resource "google_firebase_web_app" "console" {
  provider = google-beta
  project  = var.project_id

  display_name    = "Scenova review console (${var.environment})"
  deletion_policy = var.deletion_policy
}

data "google_firebase_web_app_config" "console" {
  provider   = google-beta
  project    = var.project_id
  web_app_id = google_firebase_web_app.console.app_id
}

resource "google_firebase_hosting_site" "console" {
  provider = google-beta
  project  = var.project_id
  site_id  = var.site_id
  app_id   = google_firebase_web_app.console.app_id

  deletion_policy = var.deletion_policy
}
