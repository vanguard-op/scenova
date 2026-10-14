output "site_id" {
  description = "Firebase Hosting site id the console deploys to."
  value       = google_firebase_hosting_site.console.site_id
}

output "default_url" {
  description = "Default public URL of the console (https://<site>.web.app)."
  value       = google_firebase_hosting_site.console.default_url
}

output "web_app_id" {
  description = "Firebase Web App id the Hosting site is linked to."
  value       = google_firebase_web_app.console.app_id
}

output "web_app_config" {
  description = "Firebase client config the console initialises with. A public project identifier, not a credential."
  value = {
    api_key             = data.google_firebase_web_app_config.console.api_key
    auth_domain         = data.google_firebase_web_app_config.console.auth_domain
    project_id          = var.project_id
    app_id              = google_firebase_web_app.console.app_id
    messaging_sender_id = data.google_firebase_web_app_config.console.messaging_sender_id
  }
}
