# Cloud Tasks queue for asynchronous generation jobs (architecture.md "Data Flow
# Patterns"; C-003 POST /internal/generation-jobs). A slow generation never
# blocks a lookup, and the pipeline scales on queue depth (NFR-003).

variable "project_id" { type = string }
variable "region" { type = string }
variable "environment" { type = string }
variable "queue_name" { type = string }
variable "max_dispatches_per_second" {
  description = "Dispatch ceiling; raises with generation capacity."
  type        = number
  default     = 5
}
variable "max_attempts" {
  type    = number
  default = 5
}

resource "google_cloud_tasks_queue" "generation" {
  name     = var.queue_name
  project  = var.project_id
  location = var.region

  rate_limits {
    max_dispatches_per_second = var.max_dispatches_per_second
    max_concurrent_dispatches = 20
  }

  retry_config {
    max_attempts       = var.max_attempts
    min_backoff        = "10s"
    max_backoff        = "300s"
    max_doublings      = 4
    max_retry_duration = "3600s"
  }

  stackdriver_logging_config {
    sampling_ratio = 1
  }
}
