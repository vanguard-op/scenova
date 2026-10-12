# Cloud CDN in front of the clip bucket (architecture.md "Data Architecture":
# Object Storage + CDN; write-once, read-many). The load balancer serves clips to
# readers; the bucket stays private and the app issues signed URLs.
#
# Instantiated only when cdn_domain is set for the environment.

variable "project_id" { type = string }
variable "bucket_name" { type = string }
variable "cdn_domain" { type = string }
variable "labels" { type = map(string) }

resource "google_compute_global_address" "cdn" {
  name    = "scenova-cdn-ip"
  project = var.project_id
}

resource "google_compute_backend_bucket" "clips" {
  name        = "scenova-clips-backend"
  project     = var.project_id
  bucket_name = var.bucket_name
  enable_cdn  = true

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    client_ttl        = 3600
    default_ttl       = 3600
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400
  }
}

resource "google_compute_url_map" "https" {
  name            = "scenova-cdn"
  project         = var.project_id
  default_service = google_compute_backend_bucket.clips.id
}

resource "google_compute_managed_ssl_certificate" "cdn" {
  name    = "scenova-cdn-cert"
  project = var.project_id
  managed { domains = [var.cdn_domain] }
}

resource "google_compute_target_https_proxy" "cdn" {
  name             = "scenova-cdn-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cdn.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name       = "scenova-cdn-https"
  project    = var.project_id
  target     = google_compute_target_https_proxy.cdn.id
  port_range = "443"
  ip_address = google_compute_global_address.cdn.address
}

# HTTP → HTTPS redirect.
resource "google_compute_url_map" "redirect" {
  name    = "scenova-cdn-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "scenova-cdn-http"
  project = var.project_id
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "scenova-cdn-http"
  project    = var.project_id
  target     = google_compute_target_http_proxy.redirect.id
  port_range = "80"
  ip_address = google_compute_global_address.cdn.address
}
