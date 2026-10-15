import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/entitlement_api.dart';
import 'package:scenova/services/purchase_service.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// The free plan a signed-in reader sees.
const Entitlement _free = Entitlement(
  tier: PlanTier.free,
  signedIn: true,
  lookupsUsed: 12,
  lookupsLimit: 20,
);

/// The Pro plan.
const Entitlement _pro = Entitlement(
  tier: PlanTier.pro,
  signedIn: true,
  lookupsUsed: 8,
  lookupsLimit: 50,
);

void main() {
  testWidgets('the plan holds its shape while the entitlement loads', (
    tester,
  ) async {
    final api = _DelayedEntitlementApi();
    await pumpAccount(tester, entitlementsApi: api);
    await tester.pump();

    expect(find.byType(SkeletonList), findsOneWidget);

    api.completer.complete(_free);
    await tester.pump();
    expect(find.text('Free'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a reader with no account is asked to sign in', (tester) async {
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(
        error: const EntitlementApiException(401, 'Sign in to see your plan.'),
      ),
    );
    await tester.pump();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Sign in to Scenova'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the free tier shows the allowance meter and Start Pro', (
    tester,
  ) async {
    await pumpAccount(tester, entitlementsApi: MockEntitlementApi(plan: _free));
    await tester.pump();

    expect(find.text('Free'), findsOneWidget);
    expect(find.text('12 of 20'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Start Pro'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the Pro tier shows the plan and Manage plan', (tester) async {
    await pumpAccount(tester, entitlementsApi: MockEntitlementApi(plan: _pro));
    await tester.pump();

    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('8 of 50'), findsOneWidget);
    expect(find.text('Manage plan'), findsOneWidget);
    expect(find.text('Start Pro'), findsNothing);
    await teardown(tester);
  });

  testWidgets('the trial shows its end date', (tester) async {
    final trial = Entitlement(
      tier: PlanTier.trial,
      signedIn: true,
      lookupsUsed: 3,
      lookupsLimit: 50,
      trialEndsAt: DateTime(2026, 10, 20),
    );
    await pumpAccount(tester, entitlementsApi: MockEntitlementApi(plan: trial));
    await tester.pump();

    expect(find.text('Trial'), findsOneWidget);
    expect(find.textContaining('Your free trial ends'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a purchase in progress disables the actions and spins', (
    tester,
  ) async {
    final purchases = _DelayedPurchaseService();
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      purchases: purchases,
    );
    await tester.pump();

    await tester.tap(find.text('Start Pro'));
    await tester.pump();

    final start = tester.widget<ScenovaButton>(
      find.widgetWithText(ScenovaButton, 'Start Pro'),
    );
    expect(start.isSubmitting, isTrue);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<ScenovaButton>(
            find.widgetWithText(ScenovaButton, 'Restore purchases'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<ScenovaButton>(find.widgetWithText(ScenovaButton, 'Sign out'))
          .onPressed,
      isNull,
    );

    purchases.completer.complete(const PurchaseCompleted());
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('a failed purchase shows a message and a retry', (tester) async {
    final purchases = MockPurchaseService(
      startProOutcome: const PurchaseFailed('Your payment was declined.'),
    );
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      purchases: purchases,
    );
    await tester.pump();

    await tester.tap(find.text('Start Pro'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Your payment was declined.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // The plan on screen is unchanged.
    expect(find.text('Free'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(purchases.startProCalls, 2);
    await teardown(tester);
  });

  testWidgets('an unreachable store is reported and the plan stays', (
    tester,
  ) async {
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      purchases: MockPurchaseService(offline: true),
    );
    await tester.pump();

    await tester.tap(find.text('Start Pro'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'The store is not reachable right now. Your plan has not changed.',
      ),
      findsOneWidget,
    );
    expect(find.text('Free'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a completed purchase re-reads the plan', (tester) async {
    final api = _SequencedEntitlementApi(<Entitlement>[_free, _pro]);
    await pumpAccount(
      tester,
      entitlementsApi: api,
      purchases: MockPurchaseService(),
    );
    await tester.pump();

    expect(find.text('Free'), findsOneWidget);

    await tester.tap(find.text('Start Pro'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('8 of 50'), findsOneWidget);
    expect(api.calls, 2);
    await teardown(tester);
  });

  testWidgets('a restore with nothing to restore says so', (tester) async {
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      purchases: MockPurchaseService(
        restoreOutcome: const PurchaseNothingToRestore(),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Restore purchases'));
    await tester.pump();
    await tester.pump();

    expect(find.text('No purchases to restore.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('signing in loads the plan', (tester) async {
    final session = DevelopmentAccountSession(signedIn: false);
    await pumpAccount(
      tester,
      entitlementsApi: _SessionAwareEntitlementApi(session, _free),
      accountSession: session,
    );
    await tester.pump();

    expect(find.text('Sign in to Scenova'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();

    expect(session.signInCalls, 1);
    expect(find.text('Free'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('signing out returns to the signed-out prompt', (tester) async {
    final session = DevelopmentAccountSession(signedIn: true);
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      accountSession: session,
    );
    await tester.pump();

    expect(find.text('Free'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await tester.pump();
    await tester.pump();

    expect(session.signOutCalls, 1);
    expect(find.text('Sign in to Scenova'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('an unreachable entitlement service offers a retry', (
    tester,
  ) async {
    final api = _RecoveringEntitlementApi();
    await pumpAccount(tester, entitlementsApi: api);
    await tester.pump();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('Your plan did not load'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Free'), findsOneWidget);
    await teardown(tester);
  });
}

/// An entitlement read that resolves only when the test completes it.
class _DelayedEntitlementApi implements EntitlementApi {
  final Completer<Entitlement> completer = Completer<Entitlement>();

  @override
  Future<Entitlement> fetch() => completer.future;
}

/// An entitlement read that answers each call from a script, so a purchase's
/// re-read can be seen to move the plan.
class _SequencedEntitlementApi implements EntitlementApi {
  _SequencedEntitlementApi(this.plans);

  final List<Entitlement> plans;
  int calls = 0;

  @override
  Future<Entitlement> fetch() async {
    final index = calls < plans.length ? calls : plans.length - 1;
    calls++;
    return plans[index];
  }
}

/// An entitlement read that answers only while the session is signed in, as
/// `C-018` does with its 401.
class _SessionAwareEntitlementApi implements EntitlementApi {
  _SessionAwareEntitlementApi(this.session, this.plan);

  final DevelopmentAccountSession session;
  final Entitlement plan;

  @override
  Future<Entitlement> fetch() async {
    if (!session.signedIn) {
      throw const EntitlementApiException(401, 'Sign in to see your plan.');
    }
    return plan;
  }
}

/// An entitlement read that fails once, then answers, for the retry.
class _RecoveringEntitlementApi implements EntitlementApi {
  int calls = 0;

  @override
  Future<Entitlement> fetch() async {
    calls++;
    if (calls == 1) {
      throw const EntitlementApiException(
        503,
        'The entitlement service is unavailable.',
      );
    }
    return _free;
  }
}

/// A store whose action resolves only when the test completes it.
class _DelayedPurchaseService implements PurchaseService {
  final Completer<PurchaseOutcome> completer = Completer<PurchaseOutcome>();

  @override
  Future<StoreOffering> offerings() async => const StoreOffering(
    proMonthly: StoreProduct(id: 'pro.monthly', displayPrice: r'$6.99'),
    topUp: StoreProduct(id: 'topup.20', displayPrice: r'$2.99'),
  );

  @override
  Future<PurchaseOutcome> startPro() => completer.future;

  @override
  Future<PurchaseOutcome> buyTopUp() => completer.future;

  @override
  Future<PurchaseOutcome> managePlan() => completer.future;

  @override
  Future<PurchaseOutcome> restore() => completer.future;
}
