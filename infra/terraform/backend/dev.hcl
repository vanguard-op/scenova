# Remote state for the dev environment.
#
# The state bucket is created once, before the first `terraform init`, by the
# bootstrap step documented inline in ci/checks/infra.sh and the Makefile:
#
#   gcloud storage buckets create gs://scenova-tfstate-dev \
#     --project <project> --location us-central1 --uniform-bucket-level-access
#   gcloud storage buckets update gs://scenova-tfstate-dev --versioning
#
# Each environment has its own bucket, so a plan or apply touches one environment
# at a time (release.md "Promotion rule").
bucket = "scenova-tfstate-dev"
prefix = "scenova"
