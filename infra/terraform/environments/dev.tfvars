# Development environment — synthetic data, reset freely.
# Promotion gate: automated tests pass (release.md "Environments & Promotion").
# Flags are open in dev so every feature is exercised; the paid tier stays off.

environment         = "dev"
project_id          = "scenova-dev"
region              = "us-central1"
artifact_repo       = "scenova"
clip_bucket         = "scenova-clips-dev"
firebase_project_id = "scenova-dev"

deletion_protection = false

db_tier                  = "db-f1-micro"
db_availability          = "ZONAL"
db_backup_retention_days = 7

redis_tier      = "BASIC"
redis_memory_gb = 1

alert_email = ""

labels = {
  app        = "scenova"
  env        = "dev"
  managed-by = "terraform"
}

services = {
  gateway     = { public = true }
  lookup      = { public = false }
  pipeline    = { public = false }
  library     = { public = false }
  entitlement = { public = false }
  feedback    = { public = false }
  analytics   = { public = false }
  model       = { public = false }
}

flags = {
  FLAG_ENABLE_CLIP_VIEW       = "true"
  FLAG_ENABLE_GENERATION      = "true"
  FLAG_ENABLE_PHRASE_CLIP     = "true"
  FLAG_ENABLE_OFFLINE_HISTORY = "true"
  FLAG_ENABLE_PAID_TIER       = "false"
  FLAG_SERVE_SEEDED_LIBRARY   = "true"
}
