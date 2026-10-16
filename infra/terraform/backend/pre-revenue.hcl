# Remote state for the pre-revenue environment. See backend/dev.hcl for the
# one-time bucket bootstrap. Bucket: gs://scenova-tfstate-pre-revenue
#
# The bucket must exist before `terraform init`; the lifecycle action
# (ci/lifecycle.sh) checks for it and prints the bootstrap command when it is
# missing. It is the one piece of the environment that is not created by
# Terraform itself, because Terraform needs somewhere to keep its state first.
bucket = "scenova-tfstate-pre-revenue"
prefix = "scenova"
