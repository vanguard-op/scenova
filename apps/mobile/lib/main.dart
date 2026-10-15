import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'config.dart';
import 'extension/clip_extension_app.dart';
import 'models/history_entry.dart';
import 'models/lookup.dart';
import 'services/app_services.dart';
import 'services/extension_channel.dart';
import 'services/history_store.dart';
import 'services/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final locale = WidgetsBinding.instance.platformDispatcher.locale
      .toLanguageTag();
  // The reader's lookups live on the device and outlive the launch
  // (`FEAT-009`).
  final historyStore = SharedPreferencesHistoryStore();
  // A development run seeds a few lookups so the loaded state is visible; the
  // seeds are written into the device's own store and never in a release build.
  if (kDebugMode && AppConfig.seedHistory) {
    final existing = await historyStore.all();
    if (existing.isEmpty) {
      for (final entry in _seedHistory()) {
        await historyStore.save(entry);
      }
    }
  }
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

/// A couple of lookups so Home's loaded state is visible in development.
/// `--dart-define=SCENOVA_SEED_HISTORY=false` shows the empty state instead.
List<HistoryEntry> _seedHistory() {
  if (!AppConfig.seedHistory) return const <HistoryEntry>[];
  final now = DateTime.now();
  return <HistoryEntry>[
    HistoryEntry(
      id: 'seed-come',
      word: 'come',
      phrase: 'to move towards someone or something',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(minutes: 6)),
      clipUrl: 'mock://clip/library-hit',
    ),
    HistoryEntry(
      id: 'seed-bank',
      word: 'bank',
      phrase: 'a place that keeps money safe',
      kind: LookupKind.word,
      savedAt: now.subtract(const Duration(hours: 2)),
      clipUrl: 'mock://clip/bank-money',
    ),
  ];
}
