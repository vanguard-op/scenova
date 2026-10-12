output "service_uris" {
  value = { for k, s in google_cloud_run_v2_service.this : k => s.uri }
}
output "artifact_registry" {
  value = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
