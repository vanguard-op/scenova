output "gateway_url" {
  description = "Public entry point for the mobile client (the only public service)."
  value       = module.run.service_uris["gateway"]
}

output "service_uris" {
  description = "Internal Cloud Run service URIs."
  value       = module.run.service_uris
}

output "artifact_registry" {
  description = "Artifact Registry path prefix for service images."
  value       = module.run.artifact_registry
}

output "clip_bucket" {
  description = "Cloud Storage bucket holding clip files."
  value       = module.data.bucket_name
}

output "cdn_ip" {
  description = "Cloud CDN static IP (empty when no custom domain is configured)."
  value       = var.cdn_domain == "" ? "" : module.cdn[0].cdn_ip
}

output "db_connection_name" {
  description = "Cloud SQL connection name."
  value       = module.data.db_connection_name
}

output "redis_host" {
  description = "Memorystore Redis host (private)."
  value       = module.data.redis_host
}

output "deploy_service_account" {
  description = "Service account the deploy pipeline impersonates."
  value       = google_service_account.deploy.email
}
