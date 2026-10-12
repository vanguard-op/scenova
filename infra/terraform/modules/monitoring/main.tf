# Availability and reliability monitoring (nfr.md NFR-010 to NFR-012;
# release.md "Rollback & Roll-forward" triggers). Alerts are measured signals, not
# judgement calls: an alert fires, the on-call acts.

variable "project_id" { type = string }
variable "environment" { type = string }
variable "gateway_url" { type = string }
variable "alert_email" { type = string }

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email == "" ? 0 : 1
  project      = var.project_id
  display_name = "Scenova ${var.environment} on-call"
  type         = "email"

  labels = { email_address = var.alert_email }
}

# NFR-010: 99.5% monthly for lookup and library serve.
resource "google_monitoring_uptime_check_config" "gateway" {
  project      = var.project_id
  display_name = "scenova-${var.environment}-gateway"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/healthz"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = replace(replace(var.gateway_url, "https://", ""), "http://", "")
    }
  }
}

resource "google_monitoring_alert_policy" "availability" {
  count        = var.alert_email == "" ? 0 : 1
  project      = var.project_id
  display_name = "Scenova ${var.environment} — lookup availability below target"
  combiner     = "OR"

  conditions {
    display_name = "Gateway uptime check failing"

    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.gateway.uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger { count = 1 }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
  alert_strategy { auto_close = "1800s" }
}

# NFR-012 / release.md: generation failure rate above 20% of jobs for 10 minutes
# disables `enable_generation` and serves the library and device history.
resource "google_logging_metric" "generation_failed" {
  project = var.project_id
  name    = "scenova_${var.environment}_generation_failed"
  filter  = "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"generation_failed\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_monitoring_alert_policy" "generation_failures" {
  count        = var.alert_email == "" ? 0 : 1
  project      = var.project_id
  display_name = "Scenova ${var.environment} — generation failures spiking"
  combiner     = "OR"

  conditions {
    display_name = "generation_failed events"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.generation_failed.name}\" AND resource.type=\"cloud_run_revision\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "600s"

      aggregations {
        alignment_period   = "600s"
        per_series_aligner = "ALIGN_RATE"
      }

      trigger { count = 1 }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]
  alert_strategy { auto_close = "1800s" }
}
