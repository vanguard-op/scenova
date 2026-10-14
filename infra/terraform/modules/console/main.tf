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

# The console's Web App, distinct from the reader client's: it is the identity
# Hosting links to the site and the source of the runtime client config.
resource "google_firebase_web_app" "console" {
  provider = google-beta
  project  = var.project_id

  display_name = "Scenova review console (${var.environment})"
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
}
