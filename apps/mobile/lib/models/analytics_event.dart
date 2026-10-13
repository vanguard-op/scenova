import 'package:flutter/foundation.dart';

import 'lookup.dart';

/// The product's event taxonomy (`docs/Scenova/analytics.md` → "Event Taxonomy").
///
/// Every event the client emits is one of these names. [id] is the stable
/// `EVT-###` anchor: when an event's meaning shifts, a property is added or a
/// new event introduced, and an existing name is never redefined. [keyProperties]
/// mirrors the taxonomy's key-property column so the client cannot drift into
/// free-form properties, which is where personal data would leak in.
///
/// [suppressedWithoutConsent] marks the reading-behaviour events that
/// "Analytics Data Governance" suppresses until model-processing consent is
/// granted; lifecycle and purchase events are not suppressed.
enum AnalyticsEventName {
  appOpened('EVT-001', 'app_opened', <String>{AnalyticsProperty.source}),
  onboardingCompleted('EVT-002', 'onboarding_completed', <String>{
    AnalyticsProperty.actionEnabled,
    AnalyticsProperty.consent,
  }),
  // The taxonomy's key property for this event is `platform`, which the
  // contract already carries as a common field (C-007), so it is not
  // duplicated here.
  actionEnabled('EVT-003', 'action_enabled', <String>{}),
  consentChanged('EVT-004', 'consent_changed', <String>{
    AnalyticsProperty.consent,
  }),
  lookupStarted('EVT-005', 'lookup_started', <String>{
    AnalyticsProperty.kind,
    AnalyticsProperty.source,
  }, suppressedWithoutConsent: true),
  lookupServed('EVT-006', 'lookup_served', <String>{AnalyticsProperty.entryId}),
  // Generation lifecycle events carry model_version, cost_units, and
  // duration_ms, which only the generation pipeline knows. They are emitted
  // service-side and are listed here for the taxonomy's completeness.
  generationStarted('EVT-007', 'generation_started', <String>{
    AnalyticsProperty.kind,
    AnalyticsProperty.modelVersion,
  }),
  generationCompleted('EVT-008', 'generation_completed', <String>{
    AnalyticsProperty.modelVersion,
    AnalyticsProperty.durationMs,
    AnalyticsProperty.costUnits,
    AnalyticsProperty.resolution,
  }),
  generationFailed('EVT-009', 'generation_failed', <String>{
    AnalyticsProperty.reason,
    AnalyticsProperty.modelVersion,
  }),
  clipPlayed('EVT-010', 'clip_played', <String>{
    AnalyticsProperty.entryId,
    AnalyticsProperty.clipSource,
  }, suppressedWithoutConsent: true),
  clipFeedbackGiven('EVT-011', 'clip_feedback_given', <String>{
    AnalyticsProperty.rating,
    AnalyticsProperty.clipSource,
  }),
  clipReported('EVT-012', 'clip_reported', <String>{
    AnalyticsProperty.reason,
    AnalyticsProperty.clipSource,
  }),
  historyViewed('EVT-013', 'history_viewed', <String>{
    AnalyticsProperty.itemCount,
  }, suppressedWithoutConsent: true),
  historyReplayed('EVT-014', 'history_replayed', <String>{
    AnalyticsProperty.entryId,
  }),
  historyEntryRemoved('EVT-015', 'history_entry_removed', <String>{
    AnalyticsProperty.entryId,
  }),
  preferenceChanged('EVT-016', 'preference_changed', <String>{
    AnalyticsProperty.setting,
    AnalyticsProperty.value,
  }),
  allowanceExhausted('EVT-017', 'allowance_exhausted', <String>{
    AnalyticsProperty.plan,
  }),
  paywallViewed('EVT-018', 'paywall_viewed', <String>{
    AnalyticsProperty.plan,
    AnalyticsProperty.lookupsUsed,
  }),
  purchaseStarted('EVT-019', 'purchase_started', <String>{
    AnalyticsProperty.productId,
    AnalyticsProperty.productKind,
  }),
  purchaseCompleted('EVT-020', 'purchase_completed', <String>{
    AnalyticsProperty.productId,
    AnalyticsProperty.productKind,
  }),
  purchaseFailed('EVT-021', 'purchase_failed', <String>{
    AnalyticsProperty.productId,
    AnalyticsProperty.reason,
  });

  const AnalyticsEventName(
    this.id,
    this.wire,
    this.keyProperties, {
    this.suppressedWithoutConsent = false,
  });

  /// The stable taxonomy id, e.g. `EVT-005`.
  final String id;

  /// The wire name the intake accepts, e.g. `lookup_started`.
  final String wire;

  /// The taxonomy's key properties, and the only keys the client may send.
  final Set<String> keyProperties;

  /// Whether the event is held back until model-processing consent is granted.
  final bool suppressedWithoutConsent;
}

/// The property keys the taxonomy names, so no call site spells one by hand.
abstract final class AnalyticsProperty {
  static const String source = 'source';
  static const String actionEnabled = 'action_enabled';
  static const String consent = 'consent';
  static const String kind = 'kind';
  static const String entryId = 'entry_id';
  static const String clipSource = 'clip_source';
  static const String rating = 'rating';
  static const String reason = 'reason';
  static const String itemCount = 'item_count';
  static const String setting = 'setting';
  static const String value = 'value';
  static const String plan = 'plan';
  static const String lookupsUsed = 'lookups_used';
  static const String productId = 'product_id';
  static const String productKind = 'product_kind';
  static const String modelVersion = 'model_version';
  static const String durationMs = 'duration_ms';
  static const String costUnits = 'cost_units';
  static const String resolution = 'resolution';
}

/// The `rating` values on `clip_feedback_given`.
abstract final class AnalyticsRating {
  static const String helpful = 'helpful';
  static const String notHelpful = 'not_helpful';
}

/// The `setting` values on `preference_changed`.
abstract final class AnalyticsSetting {
  static const String sound = 'sound';
  static const String reduceMotion = 'reduce_motion';
}

/// Where a lookup entered the app, the `source` property on `lookup_started`.
enum LookupSource {
  /// The Android text-selection action.
  androidAction('android_action'),

  /// The iOS share extension.
  iosExtension('ios_extension'),

  /// Typed or pasted in Scenova's own entry field.
  typed('typed');

  const LookupSource(this.wire);

  final String wire;
}

/// Why the app came to the foreground, the `source` property on `app_opened`.
enum AppOpenSource {
  launch('launch'),
  resume('resume');

  const AppOpenSource(this.wire);

  final String wire;
}

/// Where a playing clip came from, the `clip_source` property.
enum ClipSource {
  /// A clip from the shared library, referenced by its entry id.
  library('library'),

  /// A clip generated for this lookup.
  generated('generated'),

  /// A clip replayed from device history with no connection.
  saved('saved');

  const ClipSource(this.wire);

  final String wire;
}

/// One product event, as `POST /v1/events` takes it (`C-007`).
///
/// The pseudonymous `user_id` the taxonomy lists is not a field here: the
/// gateway resolves it from the authenticated token subject, and the client
/// sends only the bearer token, never an email, name, or the selected text.
@immutable
class AnalyticsEvent {
  const AnalyticsEvent({
    required this.eventId,
    required this.name,
    required this.occurredAt,
    required this.anonymousId,
    required this.sessionId,
    required this.platform,
    required this.appVersion,
    required this.locale,
    this.properties = const <String, Object?>{},
  });

  /// A unique id for this occurrence.
  final String eventId;

  final AnalyticsEventName name;

  /// When the event happened, in UTC.
  final DateTime occurredAt;

  /// The pseudonymous identifier for the install, stable across sign-in.
  final String anonymousId;

  /// The session the event belongs to.
  final String sessionId;

  final LookupPlatform platform;
  final String appVersion;
  final String locale;

  /// The taxonomy's key properties for [name]; never free text.
  final Map<String, Object?> properties;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'eventId': eventId,
    'name': name.wire,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
    'anonymousId': anonymousId,
    'sessionId': sessionId,
    'platform': platform.wire,
    'appVersion': appVersion,
    'locale': locale,
    'properties': properties,
  };
}
