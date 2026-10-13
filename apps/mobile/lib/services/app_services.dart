import 'package:flutter/widgets.dart';

import '../config.dart';
import '../models/entitlement.dart';
import '../models/history_entry.dart';
import '../models/lookup.dart';
import 'capture_channel.dart';
import 'connectivity.dart';
import 'entitlement_provider.dart';
import 'history_store.dart';
import 'identity.dart';
import 'lookup_api.dart';
import 'settings_controller.dart';

/// The collaborators the presentation layer reads.
///
/// Screens take these from [ScenovaScope] rather than constructing them, so a
/// test can swap any one of them for a scripted stand-in.
class ScenovaServices {
  ScenovaServices({
    required this.lookupApi,
    required this.identity,
    required this.historyStore,
    required this.connectivity,
    required this.settings,
    required this.entitlements,
    required this.captureChannel,
    this.locale = 'en',
  });

  final LookupApi lookupApi;

  /// The reader's identity, presented on every lookup (`C-001`/`C-002` auth).
  final IdentityProvider identity;

  final HistoryStore historyStore;
  final ConnectivityMonitor connectivity;
  final SettingsController settings;
  final EntitlementProvider entitlements;
  final CaptureChannel captureChannel;

  /// The reader's locale, sent with a lookup.
  final String locale;

  /// The development wiring: scripted data that speaks the frozen contract,
  /// an in-memory history, and a manual connectivity switch.
  factory ScenovaServices.development({
    String locale = 'en',
    Entitlement entitlement = Entitlement.unmeteredGuest,
    List<HistoryEntry> history = const <HistoryEntry>[],
  }) {
    // The identity the lookup path presents: an anonymous Firebase ID token in
    // production, and the gateway's pseudonymous dev token on a laptop
    // (`C-001`/`C-002` auth; D-011).
    final identity = AppConfig.useFirebaseAuth
        ? FirebaseIdentity()
        : AnonymousIdentity();

    return ScenovaServices(
      lookupApi: AppConfig.useMockLookupApi
          ? MockLookupApi(latency: AppConfig.mockLatency)
          : HttpLookupApi(
              baseUrl: AppConfig.apiBaseUrl,
              idTokenProvider: identity.idToken,
              localeProvider: () => locale,
            ),
      identity: identity,
      historyStore: InMemoryHistoryStore(seed: history),
      connectivity: ManualConnectivity(),
      settings: SettingsController(
        onboardingComplete: !AppConfig.runOnboarding,
        // A fresh install has not enabled the platform entry point yet, so
        // Onboarding's enable step is shown; the platform sets this once the
        // action or extension is on.
        actionEnabled: false,
      ),
      entitlements: FixedEntitlementProvider(entitlement),
      captureChannel: CaptureChannel(),
      locale: locale,
    );
  }

  void dispose() {
    connectivity.dispose();
    settings.dispose();
    captureChannel.dispose();
  }
}

/// Provides [ScenovaServices] to the widget tree.
class ScenovaScope extends InheritedWidget {
  const ScenovaScope({super.key, required this.services, required super.child});

  final ScenovaServices services;

  static ScenovaServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ScenovaScope>();
    assert(scope != null, 'ScenovaScope is missing above this widget.');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(ScenovaScope oldWidget) =>
      services != oldWidget.services;
}

/// A lookup that has been saved to device history, built from a result.
HistoryEntry historyEntryFrom(
  LookupResult result, {
  required DateTime savedAt,
  Sense? sense,
}) {
  final chosen = sense ?? (result.senses.isEmpty ? null : result.senses.first);
  return HistoryEntry(
    id: '${result.lookupId}-${chosen?.senseLabel ?? '0'}',
    word: result.displayWord,
    phrase: chosen?.glossPhrase ?? '',
    kind: result.kind,
    savedAt: savedAt,
    clipUrl: chosen?.clip?.url,
    hasAudio: chosen?.clip?.hasAudio ?? false,
  );
}
