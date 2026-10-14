"""Acceptance checks for the Android entry (FEAT-001) and the device it targets.

FEAT-001 delivers the Android text-selection entry: a Scenova entry appears in
the system selection menu, and choosing it delivers the selected text and starts
a lookup. The entry rides `android.intent.action.PROCESS_TEXT`, which exists from
Android 6.0 (API 23) -- the platform note in `docs/Scenova/overview.md`. The
in-context card is presented over the reading app from this entry
(`MainActivity`), so the app must declare a minimum Android version that has the
action at all.

These read the app's own declaration rather than a running device:

- the source manifest is the durable statement that the selection action is
  registered;
- the declared minimum Android version is read from the built app when the gate
  has built it (`make build`), and otherwise resolved from the Flutter toolchain
  the project pins (`flutter.minSdkVersion` in `build.gradle.kts`), so the check
  does not silently pass on a version the app does not actually declare.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

pytestmark = [pytest.mark.integration, pytest.mark.acceptance]

REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = (
    REPO_ROOT / "apps" / "mobile" / "android" / "app" / "src" / "main" / "AndroidManifest.xml"
)
GRADLE = REPO_ROOT / "apps" / "mobile" / "android" / "app" / "build.gradle.kts"
# The merged manifest the Android build produces for the debug variant (the APK
# `make build` assembles). When present it is the app's own declaration, resolved.
MERGED_MANIFEST = (
    REPO_ROOT
    / "apps"
    / "mobile"
    / "build"
    / "app"
    / "intermediates"
    / "merged_manifest"
    / "debug"
    / "processDebugMainManifest"
    / "AndroidManifest.xml"
)

_ANDROID = "{http://schemas.android.com/apk/res/android}"
# The API level that introduced ACTION_PROCESS_TEXT -- Android 6.0, the floor the
# docs give the Android entry (overview.md).
_PROCESS_TEXT_API = 23


def _root(path: Path) -> ET.Element:
    return ET.parse(path).getroot()


def _min_sdk(manifest: Path) -> int | None:
    uses_sdk = _root(manifest).find("uses-sdk")
    if uses_sdk is None:
        return None
    value = uses_sdk.get(f"{_ANDROID}minSdkVersion")
    if value is None or not value.isdigit():
        return None
    return int(value)


def _flutter_root() -> Path:
    """The Flutter SDK the project builds with, from the toolchain itself."""

    flutter = shutil.which("flutter")
    if flutter is None:
        pytest.fail(
            "cannot resolve the declared minimum Android version: the built app is "
            "absent and `flutter` is not on PATH, so neither the app nor the "
            "toolchain it pins can be read. Run `make build` first."
        )
    completed = subprocess.run(
        [flutter, "--version", "--machine"],
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    if completed.returncode != 0:
        pytest.fail(f"`flutter --version --machine` failed: {completed.stderr.strip()}")
    try:
        root = json.loads(completed.stdout).get("flutterRoot")
    except json.JSONDecodeError as exc:
        pytest.fail(f"`flutter --version --machine` returned unreadable output: {exc}")
    if not root:
        pytest.fail("`flutter --version --machine` named no flutterRoot")
    return Path(root)


def _flutter_default_min_sdk() -> int:
    """The minSdkVersion the Flutter toolchain applies to a new app."""

    extension = (
        _flutter_root()
        / "packages"
        / "flutter_tools"
        / "gradle"
        / "src"
        / "main"
        / "kotlin"
        / "FlutterExtension.kt"
    )
    if not extension.exists():
        pytest.fail(f"the Flutter toolchain's minSdkVersion is not at {extension}")
    match = re.search(r"val\s+minSdkVersion\s*:\s*Int\s*=\s*(\d+)", extension.read_text())
    if match is None:
        pytest.fail(f"could not read minSdkVersion from {extension}")
    return int(match.group(1))


def _declared_min_sdk() -> int:
    """The app's declared minimum Android version (API level).

    Prefers the built app; otherwise resolves the app's `minSdk` setting against
    the Flutter toolchain it delegates to.
    """

    if MERGED_MANIFEST.exists():
        resolved = _min_sdk(MERGED_MANIFEST)
        if resolved is not None:
            return resolved

    gradle = GRADLE.read_text()
    literal = re.search(r"\bminSdk\s*=\s*(\d+)", gradle)
    if literal is not None:
        return int(literal.group(1))
    if "minSdk = flutter.minSdkVersion" in gradle:
        return _flutter_default_min_sdk()
    pytest.fail(f"no minSdk could be read from {GRADLE}")


def test_the_manifest_registers_the_selection_action() -> None:
    # FEAT-001: Scenova registers as an Android text-selection action for plain
    # text, so the reader sees a Scenova entry in the selection menu.
    activities = _root(MANIFEST).findall("application/activity")
    filters = [
        intent_filter
        for activity in activities
        for intent_filter in activity.findall("intent-filter")
        if any(
            action.get(f"{_ANDROID}name") == "android.intent.action.PROCESS_TEXT"
            for action in intent_filter.findall("action")
        )
    ]
    assert filters, "the manifest declares no ACTION_PROCESS_TEXT intent filter"
    declared = {
        data.get(f"{_ANDROID}mimeType")
        for intent_filter in filters
        for data in intent_filter.findall("data")
    }
    assert "text/plain" in declared, f"the selection action does not accept text/plain: {declared}"


def test_the_declared_minimum_android_version_supports_the_entry() -> None:
    # FEAT-001 / the in-context card over the reading app: the entry is
    # ACTION_PROCESS_TEXT, which exists from Android 6.0 (API 23). The app must
    # not declare a floor below the version the entry needs, or the card cannot
    # be presented on part of the range the app claims to support.
    floor = _declared_min_sdk()
    assert floor >= _PROCESS_TEXT_API, (
        f"the app declares a minimum of API {floor}, but the Android selection "
        f"action needs API {_PROCESS_TEXT_API} (Android 6.0); the card could not be "
        "presented over the reading app on every device the app claims to support"
    )
