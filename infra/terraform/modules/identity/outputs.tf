output "name" {
  description = "Fully qualified name of the Identity Platform config (projects/<project>/config)."
  value       = google_identity_platform_config.this.name
}

output "mfa_state" {
  description = "Project second-factor policy: DISABLED, ENABLED, or MANDATORY."
  value       = google_identity_platform_config.this.mfa[0].state
}
