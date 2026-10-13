# Production environment — live readers, real data, backed up.
# Promotion gate: the go-live checklist (release.md) and store review for the
# client. The free core is at general availability; the paid tier follows the
# account phase, so it stays off until that rollout begins.

environment         = "prod"
project_id          = "scenova-prod"
region              = "us-central1"
artifact_repo       = "scenova"
clip_bucket         = "scenova-clips-prod"
firebase_project_id = "scenova-prod"
cdn_domain          = "cdn.scenova.example"

deletion_protection = true

# Production meets the 1-hour RPO for account and entitlement data (nfr.md).
db_tier                  = "db-custom-4-15360"
db_availability          = "REGIONAL"
db_backup_retention_days = 30

redis_tier      = "STANDARD_HA"
redis_memory_gb = 5

alert_email = "oncall@scenova.example"

labels = {
  app        = "scenova"
  env        = "prod"
  managed-by = "terraform"
}

services = {
  gateway      = { public = true }
  lookup       = { public = false }
  pipeline     = { public = false }
  library      = { public = false }
  entitlement  = { public = false }
  feedback     = { public = false }
  analytics    = { public = false }
  model        = { public = false }
  notification = { public = false }
}

flags = {
  FLAG_ENABLE_CLIP_VIEW       = "true"
  FLAG_ENABLE_GENERATION      = "true"
  FLAG_ENABLE_PHRASE_CLIP     = "true"
  FLAG_ENABLE_OFFLINE_HISTORY = "true"
  FLAG_ENABLE_PAID_TIER       = "false"
  FLAG_SERVE_SEEDED_LIBRARY   = "true"
}
