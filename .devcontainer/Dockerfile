# Scenova development container.
#
# Provides the full toolchain the platform needs: Python 3.12, Flutter + Android
# SDK, Terraform, the Google Cloud CLI, and Docker (added as devcontainer
# features). The same pinned versions are used in CI, so a build behaves the same
# on a laptop and in the pipeline.

FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG FLUTTER_VERSION=3.47.2
ARG ANDROID_CMDLINE_TOOLS_VERSION=13114758
ARG ANDROID_HOME=/opt/android-sdk
ARG FLUTTER_HOME=/opt/flutter

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip xz-utils git \
    && rm -rf /var/lib/apt/lists/*

# Flutter (pinned stable release).
RUN curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && rm /tmp/flutter.tar.xz \
    && git config --global --add safe.directory "${FLUTTER_HOME}"

# Android command-line tools (needed to build the APK / app bundle).
RUN mkdir -p "${ANDROID_HOME}/cmdline-tools" \
    && curl -fsSL -o /tmp/cmdline-tools.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
    && unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_HOME}/cmdline-tools" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip

ENV ANDROID_HOME="${ANDROID_HOME}" \
    ANDROID_SDK_ROOT="${ANDROID_HOME}" \
    FLUTTER_HOME="${FLUTTER_HOME}" \
    PATH="${FLUTTER_HOME}/bin:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${PATH}"

# Accept the SDK licences so `flutter build` works without an interactive step.
RUN yes | sdkmanager --licenses >/dev/null 2>&1 || true
