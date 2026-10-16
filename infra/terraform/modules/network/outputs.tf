output "vpc_id" { value = google_compute_network.vpc.id }
output "vpc_name" { value = google_compute_network.vpc.name }
output "subnet_id" { value = google_compute_subnetwork.primary.id }
# Empty in direct mode, where no connector exists.
output "connector_id" { value = try(google_vpc_access_connector.connector[0].id, "") }
output "private_services_connection" {
  value = google_service_networking_connection.private_services.id
}
