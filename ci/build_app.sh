#!/usr/bin/env bash
# Build the reader app (FEAT-013) with its store client configuration baked in.
#
# The app is built by `flutter build`, and the store client configuration —
# RevenueCat's public client SDK keys (one per store), the Pro entitlement and
# the offering the Paywall reads, and the store product catalog from
# monetization.md "Pricing Tiers" — is carried into the build as `--dart-define`
# values. They are identifiers, not credentials: they ship inside the bundle like
# the Firebase client config, and no secret is ever a build input. Prices are
# store-managed and localized, so none is baked in.
#
# The values come from `.env` locally and from the environment in CI, so the same
# command runs on a laptop and in the pipeline and each environment supplies its
# own. The store client configuration ships in every build regardless of the
# `enable_paid_tier` flag: the flag is a *runtime* Remote Config kill switch
# (release.md), so lifting it needs no new store build, and `make env` refuses a
# release flag in the define set so a build can never pin one into the client.
#
# Usage: ci/build_app.sh [apk|appbundle]   (default: appbundle)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

target="${1:-appbundle}"
case "$target" in
  apk|appbundle) ;;
  *) die "unknown target '$target' (expected apk or appbundle)" ;;
esac

has_flutter || die "no reader app to build (apps/mobile/pubspec.yaml is missing)"

# Read loop rather than `mapfile` (a bash 4 builtin): macOS ships bash 3.2, and
# the same script runs on a Mac developer's machine.
defines=()
while IFS= read -r define; do
  defines+=("$define")
done < <(mobile_dart_defines)
log "Build app · flutter build $target (store client config: ${#defines[@]} defines)"
(cd apps/mobile && flutter build "$target" --debug "${defines[@]}")
