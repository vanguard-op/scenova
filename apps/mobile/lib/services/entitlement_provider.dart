import '../models/entitlement.dart';
import 'entitlement_api.dart';

/// The reader's allowance, as the presentation layer reads it.
///
/// The concrete provider either reads the entitlement service (`C-018`) or
/// reports a fixed plan for tests and the preview gallery
/// (`docs/Scenova/user-flow.md` → "Entitlement Gate").
abstract interface class EntitlementProvider {
  /// The reader's plan and allowance, from the last read.
  Future<Entitlement> current();

  /// Re-reads the plan from the entitlement service (`C-018`).
  ///
  /// Best-effort: a read that fails leaves the last known plan in place, so an
  /// unreachable service never blocks a lookup (`C-018`; `FEAT-013` Edge Cases).
  /// A provider that reports a fixed plan has nothing to read.
  Future<void> refresh();

  /// Drops the plan to the signed-out one, for a reader who has just signed out.
  ///
  /// The cached plan would otherwise keep the paid gates until the next read
  /// confirms the sign-out, which a reader who signs out with no connection
  /// would never reach (`FEAT-013`).
  void clear();
}

/// Reads the reader's plan from the entitlement service (`C-018`).
///
/// The plan is read at launch, on each return to the foreground, and after a
/// store purchase, and cached; [current] answers from the cache so a lookup
/// never waits on the read (`NFR-002`). Before the first read the reader is held
/// to the pre-account plan, which keeps clips and caps the history at the Free
/// limit: a build that has not read the plan behaves as it did before the tiers
/// shipped, and the gates apply as soon as the plan is known.
class ApiEntitlementProvider implements EntitlementProvider {
  ApiEntitlementProvider({required this.api, Entitlement? initial})
    : _plan = initial ?? Entitlement.unmeteredGuest;

  final EntitlementApi api;
  Entitlement _plan;

  @override
  Future<Entitlement> current() async => _plan;

  @override
  void clear() => _plan = Entitlement.signedOut;

  @override
  Future<void> refresh() async {
    try {
      _plan = await api.fetch();
    } on EntitlementApiException catch (error) {
      // A 401 means the reader holds no account; anything else is the service
      // being unreachable, where the last known plan stands (`C-018`).
      if (error.isSignedOut) _plan = Entitlement.signedOut;
    } on Object {
      // The plan could not be read; the last known one stands.
    }
  }
}

/// A fixed entitlement, for tests and for viewing a given state.
class FixedEntitlementProvider implements EntitlementProvider {
  const FixedEntitlementProvider(this.value);

  final Entitlement value;

  @override
  Future<Entitlement> current() async => value;

  @override
  Future<void> refresh() async {}

  @override
  void clear() {}
}
