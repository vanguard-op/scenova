import '../models/entitlement.dart';

/// The reader's allowance.
///
/// The entitlement service and the store purchase flow are a later phase; the
/// stub reports the pre-account state, where lookups are free and unmetered
/// (`docs/Scenova/user-flow.md` → "Entitlement Gate").
abstract interface class EntitlementProvider {
  Future<Entitlement> current();
}

class StubEntitlementProvider implements EntitlementProvider {
  const StubEntitlementProvider();

  @override
  Future<Entitlement> current() async => Entitlement.unmeteredGuest;
}

/// A fixed entitlement, for tests and for viewing the allowance-exhausted
/// state.
class FixedEntitlementProvider implements EntitlementProvider {
  const FixedEntitlementProvider(this.value);

  final Entitlement value;

  @override
  Future<Entitlement> current() async => value;
}
