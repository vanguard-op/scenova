import 'package:flutter/foundation.dart';

/// The reader's plan, as `C-018` reports it.
///
/// A signed-in reader holds `free`, `trial`, or `pro`; `guest` is the
/// device-local case before sign-in, where no account backs the allowance.
enum PlanTier {
  guest,
  free,
  trial,
  pro;

  static PlanTier fromWire(Object? value) {
    return switch (value) {
      'free' => PlanTier.free,
      'trial' => PlanTier.trial,
      'pro' => PlanTier.pro,
      _ => PlanTier.guest,
    };
  }
}

/// How the entitlement service reads the account's standing (`C-018`).
enum EntitlementStatus {
  active,
  grace,
  expired;

  static EntitlementStatus fromWire(Object? value) {
    return switch (value) {
      'grace' => EntitlementStatus.grace,
      'expired' => EntitlementStatus.expired,
      _ => EntitlementStatus.active,
    };
  }
}

/// The reader's entitlement: the plan and the lookups spent this month.
///
/// `C-018` answers only for a signed-in account, so a parsed entitlement is
/// signed in; [signedOut] carries the case where the service refused the
/// caller, and [unmeteredGuest] the pre-account case where lookups are free and
/// unmetered.
@immutable
class Entitlement {
  const Entitlement({
    required this.tier,
    required this.signedIn,
    this.lookupsUsed,
    this.lookupsLimit,
    this.periodStart,
    this.periodEnd,
    this.status = EntitlementStatus.active,
    this.trialEndsAt,
    this.unmetered = false,
  });

  final PlanTier tier;
  final bool signedIn;

  /// Lookups spent in the current period.
  final int? lookupsUsed;

  /// The allowance for the current period; null when the plan carries none.
  final int? lookupsLimit;

  final DateTime? periodStart;
  final DateTime? periodEnd;
  final EntitlementStatus status;

  /// When the 7-day Pro trial ends, for a reader inside it.
  final DateTime? trialEndsAt;

  /// The pre-account case: lookups are free and unmetered
  /// (`docs/Scenova/monetization.md` → "Guest Allowance").
  final bool unmetered;

  bool get isPro => tier == PlanTier.pro;
  bool get isTrial => tier == PlanTier.trial;
  bool get isFree => tier == PlanTier.free;

  /// Whether this plan keeps a saved clip on the device, so it replays with no
  /// connection.
  ///
  /// Pro and its trial keep every saved clip; the Free tier keeps the word, the
  /// phrase, and the poster frame but not the clip, so a saved lookup replays
  /// only while online (`docs/Scenova/monetization.md` → "Feature Gate
  /// Mapping"). The pre-account case keeps clips: the tiers are not live there.
  bool get retainsClips => unmetered || isPro || isTrial;

  /// The lookups left this period, or null when the plan carries no allowance.
  int? get lookupsRemaining {
    final limit = lookupsLimit;
    if (limit == null) return null;
    final remaining = limit - (lookupsUsed ?? 0);
    return remaining < 0 ? 0 : remaining;
  }

  /// Whether every lookup in the current period has been spent.
  bool get exhausted =>
      !unmetered && lookupsLimit != null && (lookupsUsed ?? 0) >= lookupsLimit!;

  /// The reader holds no account: the screen asks them to sign in.
  static const Entitlement signedOut = Entitlement(
    tier: PlanTier.guest,
    signedIn: false,
  );

  /// The pre-account default: lookups are free and unmetered.
  static const Entitlement unmeteredGuest = Entitlement(
    tier: PlanTier.guest,
    signedIn: false,
    unmetered: true,
  );

  /// Parses `C-018`'s 200 body.
  ///
  /// A 200 answers only for an account, so the result is signed in.
  static Entitlement fromJson(Map<String, dynamic> json) {
    return Entitlement(
      tier: PlanTier.fromWire(json['plan']),
      signedIn: true,
      lookupsUsed: _intOrNull(json['lookupsUsed']),
      lookupsLimit: _intOrNull(json['lookupsLimit']),
      periodStart: _dateOrNull(json['periodStart']),
      periodEnd: _dateOrNull(json['periodEnd']),
      status: EntitlementStatus.fromWire(json['status']),
      trialEndsAt: _dateOrNull(json['trialEndsAt']),
    );
  }

  static int? _intOrNull(Object? value) {
    return switch (value) {
      final int value => value,
      final num value => value.toInt(),
      final String value => int.tryParse(value),
      _ => null,
    };
  }

  static DateTime? _dateOrNull(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}
