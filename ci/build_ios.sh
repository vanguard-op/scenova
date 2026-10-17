#!/usr/bin/env bash
# Build the iOS app and its share extension without codesigning (FEAT-002).
#
# iOS builds run on macOS with Xcode 15 or newer: as of Flutter 3.44 the engine
# and the plugins are resolved through Swift Package Manager, and `xcodebuild` is
# what produces the app. The build is deliberately unsigned (`--no-codesign`) —
# store release signing is deferred to the release workstream, so nothing here
# pins a certificate or a provisioning profile, and lifting the deferral later
# changes no build input.
#
# The share extension (FEAT-002) is a second Xcode target that runs its own
# Flutter engine. The Runner target embeds it, so `flutter build ios` builds it
# as a target dependency; the script then asserts the built `.appex` is present
# and carries an executable, because a green app build that quietly skipped the
# extension is exactly the false confidence this build exists to remove.
#
# Usage: ci/build_ios.sh   (macOS only; a no-op elsewhere so `make build` is safe)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

if [ "$(uname -s)" != "Darwin" ]; then
  skip "the iOS build runs on macOS only (this is $(uname -s)); run it on a macOS runner"
  exit 0
fi

has_flutter || die "no reader app to build (apps/mobile/pubspec.yaml is missing)"
command -v xcodebuild >/dev/null 2>&1 \
  || die "xcodebuild not found — the iOS build needs Xcode 15 or newer"

# The same store client configuration every reader-app build bakes in (FEAT-013,
# ci/build_app.sh): RevenueCat's public per-store keys and the store product
# catalog as `--dart-define` values. Identifiers, never secrets; a pipeline that
# has not seeded them passes them empty, which the SDK tolerates, so the build
# still exercises the paid-tier surface.
mapfile -t defines < <(mobile_dart_defines)

log "Build · iOS app + share extension · flutter build ios --no-codesign (${#defines[@]} defines)"
(cd apps/mobile && flutter build ios --no-codesign "${defines[@]}")

# `flutter build ios` writes the app to a fixed path; the extension is embedded
# in it. Assert both, so a missing or unbuilt second target fails here rather
# than at store submission.
app="apps/mobile/build/ios/iphoneos/Runner.app"
appex="$app/PlugIns/ShareExtension.appex"
[ -d "$app" ] || die "the iOS build produced no app bundle at $app"
[ -d "$appex" ] || die "the app built without its share extension (FEAT-002): no $appex"
[ -x "$appex/ShareExtension" ] || die "the share extension has no executable: $appex/ShareExtension"
info "app bundle:      $app"
info "share extension: $appex"

log "iOS app and share extension built (unsigned)"
