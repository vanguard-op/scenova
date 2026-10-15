import 'entitlement_provider.dart';
import 'feature_flags.dart';
import 'history_store.dart';

/// The gates the reader's plan puts on what the device keeps
/// (`docs/Scenova/monetization.md` → "Feature Gate Mapping").
///
/// The Free tier keeps the most recent lookups and no clip; Pro keeps every
/// lookup and every clip, so a saved clip replays with no connection. The
/// paid-tier kill switch reverts every reader to Free
/// (`docs/Scenova/release.md` → "Rollout Phases & Feature Flags"), so with it
/// off no plan keeps a clip and every history is capped.
class TierGates {
  const TierGates({required this.entitlements, required this.flags});

  final EntitlementProvider entitlements;
  final FeatureFlags flags;

  /// Whether the reader's plan keeps saved clips on the device.
  Future<bool> retainsClips() async {
    // With the paid tier killed every reader reverts to Free, so no plan keeps
    // a clip.
    if (!flags.paidTierEnabled) return false;
    return (await entitlements.current()).retainsClips;
  }

  /// The most lookups the device keeps, or null for no limit.
  ///
  /// Only Pro and its trial keep every lookup; the Free tier and the guest
  /// allowance keep the most recent ones
  /// (`docs/Scenova/screens/06-history.md` → Edge Cases).
  Future<int?> historyLimit() async {
    if (!flags.paidTierEnabled) return kFreeTierHistoryCapacity;
    final plan = await entitlements.current();
    return plan.isPro || plan.isTrial ? null : kFreeTierHistoryCapacity;
  }
}
