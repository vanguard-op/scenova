output "vpc_id" { value = google_compute_network.vpc.id }
output "vpc_name" { value = google_compute_network.vpc.name }
output "subnet_id" { value = google_compute_subnetwork.primary.id }
output "connector_id" { value = google_vpc_access_connector.connector.id }
output "private_services_connection" {
  value = google_service_networking_connection.private_services.id
}
