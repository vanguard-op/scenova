# Network: a single primary-region VPC with private service access for Cloud SQL
# and Memorystore, and a Serverless VPC Access connector so Cloud Run services
# reach those private addresses (architecture.md "Regions", "Deployment Topology").

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "labels" { type = map(string) }
variable "connector_name" {
  type    = string
  default = "scenova-serverless"
}
# "connector" creates a Serverless VPC Access connector (always-on: it bills at
# least two Compute Engine instances whether or not traffic flows). "direct" skips
# it and lets Cloud Run use Direct VPC egress, so the private VPC is reachable
# with no always-on resource (cloud.google.com/run/docs/configuring/vpc-direct-vpc).
variable "vpc_egress" {
  type    = string
  default = "connector"
}

resource "google_compute_network" "vpc" {
  name                    = "scenova-${var.environment}"
  project                 = var.project_id
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "primary" {
  name                     = "scenova-${var.environment}-${var.region}"
  project                  = var.project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/20"
  private_ip_google_access = true
}

# Reserved range for Cloud SQL / Memorystore private service access.
resource "google_compute_global_address" "private_services" {
  name          = "scenova-${var.environment}-private-services"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}

# Serverless connector: Cloud Run → private IPs (Cloud SQL, Redis). Created only
# in connector mode; Direct VPC egress needs no connector and no always-on
# resource.
resource "google_vpc_access_connector" "connector" {
  count         = var.vpc_egress == "connector" ? 1 : 0
  name          = var.connector_name
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.11.0.0/28"
  min_instances = 2
  max_instances = 10
}
