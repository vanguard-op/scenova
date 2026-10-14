import 'dart:async';
import 'dart:math';

import '../config.dart';
import '../models/analytics_event.dart';
import '../models/lookup.dart';
import 'analytics_api.dart';
import 'connectivity.dart';
import 'settings_controller.dart';

/// A fresh pseudonymous identifier: sixteen random bytes, hex-encoded.
///
/// Used for the install's `anonymous_id` and each session id. It carries
/// nothing about the reader.
String newAnalyticsId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Emits the product's events and delivers them to the intake (`C-007`).
///
/// The client owns the client half of "Analytics Data Governance"
/// (`docs/Scenova/analytics.md`):
/// - consent gating: the reading-behaviour events (`lookup_started`,
///   `clip_played`, `history_viewed`) are dropped until model-processing consent
///   is granted, while lifecycle and purchase events are not;
/// - no personal data: every event's properties are drawn from the taxonomy's
///   key properties, never the word, phrase, email, or name, and the
///   pseudonymous `user_id` is the gateway's token subject, not a field here;
/// - no sampling at launch: every event is kept and sent.
///
/// Events are queued and delivered in batches of at most fifty. A batch is sent
/// when the queue reaches [flushThreshold], on an explicit [flush] (the app
/// flushes on foreground and background), and when the connection returns. A
/// rejected or unauthenticated batch is dropped, since resending it cannot
/// succeed; an offline or rate-limited batch stays queued.
class AnalyticsClient {
  AnalyticsClient({
    required this.api,
    required this.settings,
    required this.connectivity,
    required this.anonymousId,
    required this.appVersion,
    this.locale = 'en',
    LookupPlatform? platform,
    String? sessionId,
    String Function()? newId,
    DateTime Function()? clock,
    this.batchSize = AppConfig.analyticsBatchSize,
    this.flushThreshold = AppConfig.analyticsFlushThreshold,
    this.queueLimit = AppConfig.analyticsQueueLimit,
  }) : platform = platform ?? LookupPlatform.current(),
       _newId = newId ?? newAnalyticsId,
       _sessionId = sessionId ?? newAnalyticsId(),
       _clock = clock ?? DateTime.now {
    _connectivitySub = connectivity.changes.listen((online) {
      if (online) unawaited(flush());
    });
  }

  final AnalyticsApi api;
  final SettingsController settings;
  final ConnectivityMonitor connectivity;

  /// The pseudonymous identifier for the install, stable across sign-in.
  final String anonymousId;
  final String appVersion;
  final String locale;
  final LookupPlatform platform;

  /// The contract's batch cap (`C-007`, at most fifty).
  final int batchSize;

  /// How many queued events trigger a send.
  final int flushThreshold;

  /// A safety valve so an offline queue cannot grow without bound.
  final int queueLimit;

  final String Function() _newId;
  final String _sessionId;
  final DateTime Function() _clock;

  final List<AnalyticsEvent> _queue = <AnalyticsEvent>[];
  late final StreamSubscription<bool> _connectivitySub;
  bool _flushing = false;
  bool _disposed = false;

  /// Events queued but not yet accepted by the intake.
  List<AnalyticsEvent> get pending => List<AnalyticsEvent>.unmodifiable(_queue);

  int get pendingCount => _queue.length;

  /// Records one event. A reading-behaviour event is dropped when consent for
  /// model processing is absent.
  void track(
    AnalyticsEventName name, {
    Map<String, Object?> properties = const <String, Object?>{},
  }) {
    if (name.suppressedWithoutConsent && !settings.consentModelProcessing) {
      return;
    }
    assert(
      name.keyProperties.containsAll(properties.keys),
      'Analytics properties for ${name.wire} must be drawn from '
      '${name.keyProperties}; free-form keys could carry personal data.',
    );
    _enqueue(
      AnalyticsEvent(
        eventId: _newId(),
        name: name,
        occurredAt: _clock().toUtc(),
        anonymousId: anonymousId,
        sessionId: _sessionId,
        platform: platform,
        appVersion: appVersion,
        locale: locale,
        properties: Map<String, Object?>.unmodifiable(properties),
      ),
    );
  }

  /// The app came to the foreground (`EVT-001`).
  void appOpened({required AppOpenSource source}) => track(
    AnalyticsEventName.appOpened,
    properties: <String, Object?>{AnalyticsProperty.source: source.wire},
  );

  /// First-run setup finished or was skipped (`EVT-002`).
  void onboardingCompleted({
    required bool actionEnabled,
    required bool consent,
  }) => track(
    AnalyticsEventName.onboardingCompleted,
    properties: <String, Object?>{
      AnalyticsProperty.actionEnabled: actionEnabled,
      AnalyticsProperty.consent: consent,
    },
  );

  /// The selection action or extension was turned on (`EVT-003`). Its `platform`
  /// key property is the event's common `platform` field, so it is not repeated.
  void actionEnabled() => track(AnalyticsEventName.actionEnabled);

  /// Consent for model processing changed (`EVT-004`).
  void consentChanged({required bool consent}) => track(
    AnalyticsEventName.consentChanged,
    properties: <String, Object?>{AnalyticsProperty.consent: consent},
  );

  /// A word or phrase was received (`EVT-005`).
  void lookupStarted({
    required LookupKind kind,
    required LookupSource source,
  }) => track(
    AnalyticsEventName.lookupStarted,
    properties: <String, Object?>{
      AnalyticsProperty.kind: kind.wire,
      AnalyticsProperty.source: source.wire,
    },
  );

  /// A lookup was served from the shared library (`EVT-006`).
  void lookupServed({required String entryId}) => track(
    AnalyticsEventName.lookupServed,
    properties: <String, Object?>{AnalyticsProperty.entryId: entryId},
  );

  /// A clip played in the Clip View (`EVT-010`).
  void clipPlayed({required ClipSource clipSource, String? entryId}) => track(
    AnalyticsEventName.clipPlayed,
    properties: <String, Object?>{
      AnalyticsProperty.clipSource: clipSource.wire,
      AnalyticsProperty.entryId: ?entryId,
    },
  );

  /// The reader rated a clip (`EVT-011`). The `rating` is a clip rating's wire
  /// value — the taxonomy's `rating` property.
  void clipFeedbackGiven({
    required String rating,
    required ClipSource clipSource,
  }) => track(
    AnalyticsEventName.clipFeedbackGiven,
    properties: <String, Object?>{
      AnalyticsProperty.rating: rating,
      AnalyticsProperty.clipSource: clipSource.wire,
    },
  );

  /// The reader reported a clip (`EVT-012`).
  void clipReported({required String reason, required ClipSource clipSource}) =>
      track(
        AnalyticsEventName.clipReported,
        properties: <String, Object?>{
          AnalyticsProperty.reason: reason,
          AnalyticsProperty.clipSource: clipSource.wire,
        },
      );

  /// History was opened (`EVT-013`).
  void historyViewed({required int itemCount}) => track(
    AnalyticsEventName.historyViewed,
    properties: <String, Object?>{AnalyticsProperty.itemCount: itemCount},
  );

  /// A saved clip replayed from the device (`EVT-014`).
  void historyReplayed({required String entryId}) => track(
    AnalyticsEventName.historyReplayed,
    properties: <String, Object?>{AnalyticsProperty.entryId: entryId},
  );

  /// A saved lookup was removed (`EVT-015`).
  void historyEntryRemoved({required String entryId}) => track(
    AnalyticsEventName.historyEntryRemoved,
    properties: <String, Object?>{AnalyticsProperty.entryId: entryId},
  );

  /// A preference changed (`EVT-016`).
  void preferenceChanged({required String setting, required Object? value}) =>
      track(
        AnalyticsEventName.preferenceChanged,
        properties: <String, Object?>{
          AnalyticsProperty.setting: setting,
          AnalyticsProperty.value: value,
        },
      );

  /// The month's allowance was spent (`EVT-017`).
  void allowanceExhausted({required String plan}) => track(
    AnalyticsEventName.allowanceExhausted,
    properties: <String, Object?>{AnalyticsProperty.plan: plan},
  );

  /// The Paywall sheet opened (`EVT-018`).
  void paywallViewed({required String plan, required int lookupsUsed}) => track(
    AnalyticsEventName.paywallViewed,
    properties: <String, Object?>{
      AnalyticsProperty.plan: plan,
      AnalyticsProperty.lookupsUsed: lookupsUsed,
    },
  );

  /// A store purchase started (`EVT-019`).
  void purchaseStarted({
    required String productId,
    required String productKind,
  }) => track(
    AnalyticsEventName.purchaseStarted,
    properties: <String, Object?>{
      AnalyticsProperty.productId: productId,
      AnalyticsProperty.productKind: productKind,
    },
  );

  /// A purchase succeeded (`EVT-020`).
  void purchaseCompleted({
    required String productId,
    required String productKind,
  }) => track(
    AnalyticsEventName.purchaseCompleted,
    properties: <String, Object?>{
      AnalyticsProperty.productId: productId,
      AnalyticsProperty.productKind: productKind,
    },
  );

  /// A purchase failed (`EVT-021`).
  void purchaseFailed({required String productId, required String reason}) =>
      track(
        AnalyticsEventName.purchaseFailed,
        properties: <String, Object?>{
          AnalyticsProperty.productId: productId,
          AnalyticsProperty.reason: reason,
        },
      );

  void _enqueue(AnalyticsEvent event) {
    if (_disposed) return;
    _queue.add(event);
    if (_queue.length > queueLimit) {
      _queue.removeRange(0, _queue.length - queueLimit);
    }
    if (_queue.length >= flushThreshold) unawaited(flush());
  }

  /// Sends the queued events, oldest first, in batches of at most [batchSize].
  ///
  /// Returns when the queue is empty, the device is offline, or the intake asks
  /// the client to slow down. An offline or rate-limited batch stays queued for
  /// the next attempt; a rejected or unauthenticated batch is dropped.
  Future<void> flush() async {
    if (_disposed || _flushing || _queue.isEmpty) return;
    if (!connectivity.isOnline) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final batch = _queue.take(batchSize).toList(growable: false);
        try {
          await api.send(batch);
          _queue.removeRange(0, batch.length);
        } on AnalyticsApiException catch (error) {
          if (error.isOffline || error.isRetryable) break;
          _queue.removeRange(0, batch.length);
        }
      }
    } finally {
      _flushing = false;
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_connectivitySub.cancel());
  }
}
