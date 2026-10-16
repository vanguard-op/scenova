terraform {
  required_version = ">= 1.9"

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
