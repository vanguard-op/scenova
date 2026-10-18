import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'config.dart';
import 'dev/development_history.dart';
import 'extension/clip_extension_app.dart';
import 'services/app_services.dart';
import 'services/extension_channel.dart';
import 'services/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = WidgetsBinding.instance.platformDispatcher.locale
      .toLanguageTag();
  // The reader's lookups live on the device and outlive the launch
  // (`FEAT-009`). A development run can opt into a few sample lookups so the
  // loaded state is visible; the samples are held in memory for that run, so
  // they never reach the store the reader's own history lives in and never
  // persist. A release build carries none.
  final historyStore = launchHistoryStore(
    seed: kDebugMode && AppConfig.seedHistory,
  );
  final services = ScenovaServices.development(
    locale: locale,
    historyStore: historyStore,
  );
  // The reader's stored settings are read before the first frame, so the app
  // opens on the surface they left it on rather than back at Onboarding. The
  // release flags refresh in the background: the fallback is the healthy state,
  // so the first frame never waits on the network for a kill switch.
  await services.settings.load();
  unawaited(services.featureFlags.refresh());
  // A reader who opens the app already holding an account reads their stored
  // consent and selection-label language back onto this device, so the choices
  // they made elsewhere are in effect here (`C-022`). It runs behind the first
  // frame; the device copy stands until the account answers.
  unawaited(services.accountPreferences.adopt());
  // The reader's plan is read in the background too, so the tier gates and the
  // allowance are live without holding up the first frame; the cached plan
  // starts signed out, which is the safe default.
  unawaited(services.entitlements.refresh());
  // The entry point is read before the first frame too, so a launch from the
  // Android selection action opens the clip in place rather than flashing Home.
  final entryPoint = await services.captureChannel.entryPoint();
  // Whether the entry point is already enabled is the platform's answer, read
  // here so Onboarding skips the enable step when it is and Home does not ask
  // the reader to enable an action that is (`FEAT-001`, `FEAT-002`). An answer
  // the platform cannot give leaves the guide in place, the safe default.
  services.settings.applyEntryPoint(
    await services.captureChannel.entryPointEnabled(),
  );
  runApp(ScenovaApp(services: services, entryPoint: entryPoint));
}

/// The iOS share extension's entrypoint (`FEAT-002`).
///
/// The extension hosts this in its own sheet so the clip view opens over the
/// reading app and returns the reader to their page when dismissed. It runs the
/// clip view alone — no Home, no router — for the selection the extension hands
/// over the capture channel.
@pragma('vm:entry-point')
void clipExtensionMain() {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = WidgetsBinding.instance.platformDispatcher.locale
      .toLanguageTag();
  runApp(
    ClipExtensionApp(
      // The extension runs in its own process and starts from the same defaults
      // as a fresh app, so it keeps its settings in memory rather than reading
      // the app's suite.
      services: ScenovaServices.development(
        locale: locale,
        settingsStore: InMemorySettingsStore(),
      ),
      extensionChannel: ExtensionChannel(),
    ),
  );
}
