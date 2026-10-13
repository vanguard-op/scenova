# Staging environment — anonymized production-like data.
# Promotion gate: tests, NFR smoke checks, and a security scan pass
# (release.md "Environments & Promotion"). Mirrors production shape; the paid
# tier is exercised here before production.

environment         = "staging"
project_id          = "scenova-staging"
region              = "us-central1"
artifact_repo       = "scenova"
clip_bucket         = "scenova-clips-staging"
firebase_project_id = "scenova-staging"

deletion_protection = false

db_tier                  = "db-custom-2-3840"
db_availability          = "ZONAL"
db_backup_retention_days = 7

redis_tier      = "BASIC"
redis_memory_gb = 1

alert_email = "oncall@scenova.example"

labels = {
  app        = "scenova"
  env        = "staging"
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
  FLAG_ENABLE_PAID_TIER       = "true"
  FLAG_SERVE_SEEDED_LIBRARY   = "true"
}
