import 'package:flutter/foundation.dart';

/// The reader's plan, as far as the client needs to know it.
enum PlanTier {
  /// Signed out, using the device-local guest allowance.
  guest,
  free,
  trial,
  pro;

  static PlanTier fromWire(Object? value) {
    return switch (value) {
      'guest' => PlanTier.guest,
      'free' => PlanTier.free,
      'trial' => PlanTier.trial,
      'pro' => PlanTier.pro,
      _ => PlanTier.guest,
    };
  }
}

/// The entitlement state that Home and Clip View read for the allowance.
///
/// Before tiers ship, lookups are free and unmetered
/// (`docs/Scenova/user-flow.md` → "Entitlement Gate"); [unmetered] carries that
/// case so the allowance indicator reads honestly rather than showing a
/// fabricated number.
@immutable
class Entitlement {
  const Entitlement({
    required this.tier,
    required this.signedIn,
    this.lookupsRemaining,
    this.unmetered = false,
  });

  final PlanTier tier;
  final bool signedIn;
  final int? lookupsRemaining;
  final bool unmetered;

  bool get exhausted => !unmetered && (lookupsRemaining ?? 0) <= 0;

  /// The pre-account default: lookups are free and unmetered.
  static const Entitlement unmeteredGuest = Entitlement(
    tier: PlanTier.guest,
    signedIn: false,
    unmetered: true,
  );
}
