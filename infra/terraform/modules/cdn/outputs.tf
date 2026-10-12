output "cdn_ip" { value = google_compute_global_address.cdn.address }
output "cdn_base_url" { value = "https://${var.cdn_domain}" }
