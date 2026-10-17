# Pre-revenue environment (D-034) — the free-tier shape that runs before there
# are readers. It targets the product's single Google project (`scenova-hq`), not
# the per-environment projects dev/staging/prod describe, because pre-revenue
# there is one environment and no promotion ladder yet.
#
# What this shape deliberately gives up, and why (nfr.md "Availability &
# Reliability"): the production shape exists to meet NFR-010 (99.5% lookup),
# NFR-011 (99.9% account/entitlement), NFR-012 (99.0% generation), and the RPO/RTO
# objectives. There are no readers yet, so none of that buys anything; every
# choice here reverses by configuration because the stores sit behind ports. The
# cost of that decision is a cold start, no cross-replica rate-limit counter, no
# CDN, and a shorter backup retention — all stated at the point they are made.
#
# The lifecycle (`.github/workflows/lifecycle.yml`, `make env-*`) starts, pauses,
# and destroys this environment on demand, so the paid resources exist only
# during testing windows.

environment         = "pre-revenue"
project_id          = "scenova-hq"
region              = "us-central1"
artifact_repo       = "scenova"
clip_bucket         = "scenova-clips-pre-revenue"
firebase_project_id = "scenova-hq"
# The Firebase Hosting site already exists on this project (it was initialised
# with Firebase), so the site, its Web App, and the Identity Platform config
# (modules/identity/main.tf) are adopted once with `terraform import` before the
# first apply. `make bootstrap` (ci/bootstrap.sh) runs those imports, alongside
# the billing check, the API enablement, and the state bucket, so the first
# `make env-start` changes the existing resources instead of recreating them.
console_site_id = "scenova-hq"

# The curator MFA gate (NFR-020) and auth activity logging (NFR-029) are Identity
# Platform (GCIP) features. The Firebase free-tier shape (D-034) originally left
# the project on Firebase Auth without them; the review console ships in this
# phase, so the project is upgraded to Identity Platform and both are turned on
# here — the curator gate is a console feature, not a production-only one, and an
# operator refusal has to be auditable from the first operator. The audit trail
# keeps the Cloud Audit Logs (secretmanager, iam) and the review service's own
# append-only log as well.
#
# Cost note, stated plainly: the upgrade itself is free, but auth activity
# logging writes every sign-in and every curator-gate refusal to Cloud Logging,
# which is billed on ingestion beyond the always-free allotment. This is a real,
# ongoing (if small) charge in the pre-revenue shape, and the one deliberate
# exception to "nothing bills while idle" (D-034).
identity_gcip = true

# The provider credentials (Gemini, RevenueCat) are written out-of-band. All
# three are seeded, so all three mount: the Gemini key and the RevenueCat API key
# on the model and entitlement services, and the RevenueCat webhook
# authorization on the entitlement service, so the store billing sync (C-019) is
# authenticated by the processor's signed webhook as well as the internal service
# audience. Cloud Run refuses to mount a secret with no version, which is why
# each credential's mount is separate: a credential goes live on its service as
# soon as it is written, and one that has no value yet stays unmounted.
mount_gemini_secret           = true
mount_revenuecat_api_key      = true
mount_revenuecat_webhook_auth = true

# The data must survive every lifecycle action (nfr.md "Privacy & Compliance":
# account and entitlement data lives for the life of the account, financial
# records for seven years, shared library entries until retired). Two guards:
# Cloud SQL's API-level deletion protection, and Terraform's own deletion policy
# on the stateful resources. Both make a stray `terraform destroy` fail instead
# of taking the data.
deletion_protection  = true
data_deletion_policy = "PREVENT"

# The cheapest reachable PostgreSQL: db-f1-micro is the shared-core floor
# (~$8/month in us-central1, no free tier — Cloud SQL has none), HDD storage is
# the cheapest disk, and the smallest 10 GB disk holds an environment with no
# readers. db-f1-micro is Enterprise-edition only, which is the default.
#
# Backup retention is the 1-day minimum, not the production 7/30 days: the RPO
# the production shape meets (nfr.md: 1 hour for account/entitlement) is not
# bought before there are accounts. Point-in-time recovery stays on — it costs
# ~nothing on an empty database and it is what protects the data a teardown may
# not lose.
db_tier                  = "db-f1-micro"
db_availability          = "ZONAL"
db_disk_type             = "PD_HDD"
db_disk_size_gb          = 10
db_backup_retention_days = 1
# The lifecycle's start state. `make env-pause` / `make env-destroy` override
# this to NEVER, which stops the instance (compute billing ends, the disk and its
# data stay) — this is the one always-on paid resource in the shape.
db_activation_policy = "ALWAYS"

# No Redis: Memorystore has no free tier and a 1 GB BASIC instance bills ~$35 a
# month whether or not anything reads it. The gateway falls back to its in-memory
# rate-limit counters (REDIS_URL is empty; services/gateway/app/ratelimit.py), so
# the stack boots with no Redis in the path. The cost is that the counters are
# per-replica rather than shared — the production shape's reason for Memorystore
# (NFR-010, 50 rps sustained) is not bought before there is traffic.
enable_redis = false

# Scale to zero: no min instances on any service, so an idle service bills
# nothing (an idle *minimum* instance is billed at Cloud Run's idle rate even
# with no traffic; cloud.google.com/run/pricing). The cost is a cold start on the
# first request after an idle period — the availability NFR-010 asks for is not
# bought before there are readers.
gateway_min_instances = 0

# Direct VPC egress instead of a Serverless VPC Access connector: the connector
# bills at least two Compute Engine instances 24/7, and the free-tier shape has
# no always-on infrastructure. Cloud Run and the migration job reach the private
# Cloud SQL instance through their own network interface instead.
vpc_egress = "direct"

# The runtime is up in the start state; pause/destroy remove it.
runtime_enabled = true

# No CDN: cdn_domain is left unset, so the load balancer and CDN are not created
# (they bill hourly whether or not anything is served). Clips are served straight
# from the bucket. The cost is the delivery network the production shape fronts
# the bucket with — not bought before there is a library to serve.
# cdn_domain = ""

# No on-call before readers: an empty alert email keeps the alert policies off
# (they also need a gateway to probe, which pause/destroy removes).
alert_email = ""

labels = {
  app        = "scenova"
  env        = "pre-revenue"
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

# The release defaults from release.md "Rollout Phases & Feature Flags", exactly
# as `.env.example` declares them: pre-revenue changes no flag. Generation and
# the paid tier stay off, so nothing spends on the model provider before the
# judged quality bars (NFR-050 to NFR-053) are met, and `serve_seeded_library`
# stays on as at launch. The entitlement tier figures live in infra/terraform
# and are likewise unchanged.
flags = {
  FLAG_ENABLE_CLIP_VIEW       = "false"
  FLAG_ENABLE_GENERATION      = "false"
  FLAG_ENABLE_PHRASE_CLIP     = "false"
  FLAG_ENABLE_OFFLINE_HISTORY = "false"
  FLAG_ENABLE_PAID_TIER       = "false"
  FLAG_SERVE_SEEDED_LIBRARY   = "true"
}
