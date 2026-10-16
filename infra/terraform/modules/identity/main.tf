# Identity Platform: the project's sign-in configuration and the curator role's
# multi-factor gate (architecture.md "Review Console" and "Authentication &
# Authorization"; nfr.md NFR-020, "multi-factor required for admin roles";
# user-flow.md "Console Access Gate").
#
# Identity Platform is a project singleton: it exists once a project has Firebase
# Authentication enabled, so on an already-initialised project it is adopted once
# with
#
#   terraform import module.identity.google_identity_platform_config.this projects/<project_id>
#
# (run by `make bootstrap`, ci/bootstrap.sh) rather than created. Terraform then
# owns the second-factor policy; the sign-in providers are declared to match the
# product (an anonymous identity before an account, email for the account) so
# this file stays the one place that describes who can sign in.
#
# The gate: MFA is ENABLED for the project (available, not mandatory, so the
# reader path never asks for a second factor) with TOTP as the operator factor.
# A curator session must present an MFA-verified ID token; the console and the
# review service both refuse a session without one and the attempt is logged
# (NFR-029). The curator role itself is the `curator` custom claim, granted per
# operator by `make curator` (ci/curator.sh) — never by this file, because a role
# belongs to an account, not to the platform.

variable "project_id" { type = string }

variable "authorized_domains" {
  description = "Domains authorized for OAuth redirects: the console's hosting domains and localhost."
  type        = list(string)
}

variable "gcip" {
  description = "The project is on Identity Platform (GCIP), which the GCIP-only MFA gate (NFR-020) and auth activity logging (NFR-029) require. On for the production shape; off for the pre-revenue Firebase free-tier shape (D-034), which does not upgrade the project's identity product."
  type        = bool
  default     = true
}

resource "google_identity_platform_config" "this" {
  project                    = var.project_id
  autodelete_anonymous_users = true

  sign_in {
    # An account is the reader's own; a duplicate email would let one reader hold
    # another's entitlement.
    allow_duplicate_emails = false

    # Before accounts ship the client runs anonymously (D-011); the anonymous
    # identity is upgraded to the account at sign-in.
    anonymous {
      enabled = true
    }

    email {
      enabled           = true
      password_required = true
    }
  }

  # MFA and activity logging are GCIP-only: on a Firebase-only project the API
  # refuses them ("MFA can only be enabled in GCIP or Firebase Auth upgraded to
  # aligned product"; "activity logging can only be enabled in GCIP"). The
  # pre-revenue free-tier shape (D-034) does not upgrade the project's identity
  # product, so both are off there and the production shape turns them back on by
  # configuration. Sign-in, the anonymous identity, and the authorized domains
  # apply on Firebase Auth either way.
  dynamic "mfa" {
    for_each = var.gcip ? [1] : []
    content {
      # Enabled for the project, not mandatory: the reader path never asks for a
      # second factor, while the operator path requires one.
      state = "ENABLED"

      provider_configs {
        state = "ENABLED"

        # TOTP is the operator's second factor. Phone SMS is deliberately not
        # enabled: it is the weaker factor and would attach a phone number to an
        # operator account for no benefit.
        totp_provider_config {
          adjacent_intervals = 1
        }
      }
    }
  }

  authorized_domains = var.authorized_domains

  # Auth events are logged to Cloud Logging (NFR-029): the curator gate's refusals
  # and sign-ins are auditable alongside the privileged actions the review service
  # records.
  dynamic "monitoring" {
    for_each = var.gcip ? [1] : []
    content {
      request_logging {
        enabled = true
      }
    }
  }
}
