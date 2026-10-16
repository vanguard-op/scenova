terraform {
  required_version = ">= 1.9"

  # Remote state, one bucket per environment: backend/<env>.hcl supplies `bucket`
  # and `prefix` through `-backend-config`, so this one root module is
  # instantiated once per environment with its own state and a plan touches one
  # environment at a time (release.md "Promotion rule"). The block must exist for
  # the `-backend-config` to apply; without it Terraform silently falls back to
  # the local backend and the state stays on one machine's disk.
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Some APIs the shape calls (Identity Platform, Firebase) require a quota
# project, which Application Default Credentials do not send as a header by
# default; without this, managing the Identity Platform config fails with "API
# requires a quota project". Pinning the project as the billing/quota project
# makes every call attributable to the environment it configures.
provider "google" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}
