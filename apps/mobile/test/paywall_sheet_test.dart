import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/screens/paywall_controller.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/purchase_service.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/widgets/paywall_sheet.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// The exhausted Free plan the Paywall is opened for.
const Entitlement _exhaustedFree = Entitlement(
  tier: PlanTier.free,
  signedIn: true,
  lookupsUsed: 20,
  lookupsLimit: 20,
);

/// A Pro plan whose 50 lookups are spent, so the top-up is the offer.
const Entitlement _exhaustedPro = Entitlement(
  tier: PlanTier.pro,
  signedIn: true,
  lookupsUsed: 50,
  lookupsLimit: 50,
);

/// A plan being removed: a refund or a lapsed subscription.
const Entitlement _refundingPro = Entitlement(
  tier: PlanTier.pro,
  signedIn: true,
  lookupsUsed: 50,
  lookupsLimit: 50,
  status: EntitlementStatus.expired,
);

/// A reader who holds no account.
const Entitlement _signedOut = Entitlement(
  tier: PlanTier.guest,
  signedIn: false,
);

/// Opens the Paywall sheet on its own so a test drives its states and reads what
/// came of the visit.
Future<ScenovaServices> pumpPaywall(
  WidgetTester tester, {
  Entitlement entitlement = _exhaustedFree,
  PurchaseService? purchases,
  AccountSession? session,
  PaywallController? controller,
  ValueChanged<PaywallOutcome?>? onOutcome,
}) async {
  usePhoneWindow(tester);
  final services = buildServices(purchases: purchases, accountSession: session);
  await tester.pumpWidget(
    ScenovaScope(
      services: services,
      child: MaterialApp(
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: DeviceClass.mobile,
        ),
        home: _PaywallHost(
          entitlement: entitlement,
          controller: controller,
          onOutcome: onOutcome,
        ),
      ),
    ),
  );
  // The host opens the sheet in a post-frame callback; the sheet then settles
  // in and the offering resolves.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  return services;
}

/// A host that opens the Paywall sheet once mounted and records what came of it.
class _PaywallHost extends StatefulWidget {
  const _PaywallHost({
    required this.entitlement,
    this.controller,
    this.onOutcome,
  });

  final Entitlement entitlement;
  final PaywallController? controller;
  final ValueChanged<PaywallOutcome?>? onOutcome;

  @override
  State<_PaywallHost> createState() => _PaywallHostState();
}

class _PaywallHostState extends State<_PaywallHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final outcome = await showPaywallSheet(
      context,
      entitlement: widget.entitlement,
      controller: widget.controller,
    );
    widget.onOutcome?.call(outcome);
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

void main() {
  testWidgets('the exhausted allowance shows the meter and both options', (
    tester,
  ) async {
    await pumpPaywall(tester);

    expect(find.text("You've used this month's lookups"), findsOneWidget);
    expect(find.text('20 of 20'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // The Pro option carries the store's price and the trial.
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text(r'$6.99 a month'), findsOneWidget);
    expect(find.text('7-day free trial'), findsOneWidget);
    // The top-up option carries its own price.
    expect(find.text('20 more lookups'), findsOneWidget);
    expect(find.text(r'$2.99'), findsOneWidget);
    // The three actions, in hierarchy order.
    expect(find.text('Start Pro'), findsOneWidget);
    expect(find.text('Buy a top-up'), findsOneWidget);
    expect(find.text('Continue without a clip'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the offering holds its shape while it loads', (tester) async {
    await pumpPaywall(
      tester,
      purchases: MockPurchaseService(
        offeringLatency: const Duration(seconds: 30),
      ),
    );

    expect(find.byType(SkeletonList), findsOneWidget);
    expect(find.text('Start Pro'), findsNothing);

    await tester.pump(const Duration(seconds: 30));
    expect(find.text('Start Pro'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a purchase in flight disables the actions and shows a spinner', (
    tester,
  ) async {
    await pumpPaywall(
      tester,
      purchases: MockPurchaseService(latency: const Duration(seconds: 30)),
    );

    await tester.tap(find.text('Start Pro'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Buy a top-up'), findsOneWidget);

    // Let the store sheet resolve so no timer outlives the test.
    await tester.pump(const Duration(seconds: 30));
    await teardown(tester);
  });

  testWidgets('a failed purchase stays open with a message and a retry', (
    tester,
  ) async {
    await pumpPaywall(
      tester,
      purchases: MockPurchaseService(
        startProOutcome: const PurchaseFailed(
          'Your payment was declined. Try another payment method.',
        ),
      ),
    );

    await tester.tap(find.text('Start Pro'));
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Your payment was declined. Try another payment method.'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets(
    'a store that cannot be reached is told, and the reader can go on',
    (tester) async {
      await pumpPaywall(tester, purchases: MockPurchaseService(offline: true));

      expect(
        find.text(
          'The store is not reachable right now. You can keep reading without a '
          'clip.',
        ),
        findsOneWidget,
      );
      expect(find.text('Continue without a clip'), findsOneWidget);
      expect(find.text('Start Pro'), findsNothing);
      await teardown(tester);
    },
  );

  testWidgets('a reader with no account is asked to sign in first', (
    tester,
  ) async {
    await pumpPaywall(tester, entitlement: _signedOut);

    expect(find.text('Sign in first'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Continue without a clip'), findsOneWidget);
    expect(find.text('Start Pro'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a reader who already holds Pro is offered the top-up, not Pro', (
    tester,
  ) async {
    await pumpPaywall(tester, entitlement: _exhaustedPro);

    expect(find.text('Start Pro'), findsNothing);
    expect(find.text('Pro'), findsNothing);
    expect(find.text('20 more lookups'), findsOneWidget);
    expect(find.text('Buy a top-up'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a plan being removed is shown without a new charge', (
    tester,
  ) async {
    await pumpPaywall(tester, entitlement: _refundingPro);

    expect(
      find.text('Your plan is being removed, so nothing is charged here.'),
      findsOneWidget,
    );
    expect(find.text('Start Pro'), findsNothing);
    expect(find.text('Buy a top-up'), findsNothing);
    expect(find.text('Continue without a clip'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('starting Pro closes the sheet with the purchase', (
    tester,
  ) async {
    PaywallOutcome? outcome;
    await pumpPaywall(
      tester,
      onOutcome: (value) => outcome = value,
      purchases: MockPurchaseService(),
    );

    await tester.tap(find.text('Start Pro'));
    await tester.pumpAndSettle();

    expect(outcome, PaywallOutcome.proStarted);
    await teardown(tester);
  });

  testWidgets('buying a top-up closes the sheet with the purchase', (
    tester,
  ) async {
    PaywallOutcome? outcome;
    await pumpPaywall(
      tester,
      onOutcome: (value) => outcome = value,
      purchases: MockPurchaseService(),
    );

    await tester.tap(find.text('Buy a top-up'));
    await tester.pumpAndSettle();

    expect(outcome, PaywallOutcome.topUpBought);
    await teardown(tester);
  });

  testWidgets('continuing without a clip dismisses the sheet', (tester) async {
    var called = false;
    await pumpPaywall(tester, onOutcome: (_) => called = true);

    await tester.tap(find.text('Continue without a clip'));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(find.text('Start Pro'), findsNothing);
    await teardown(tester);
  });

  testWidgets('the sheet records the view and the purchase', (tester) async {
    final services = await pumpPaywall(tester);

    final viewed = services.analytics.pending.single;
    expect(viewed.name.wire, 'paywall_viewed');
    expect(viewed.properties, <String, Object?>{
      'plan': 'free',
      'lookups_used': 20,
    });

    await tester.tap(find.text('Start Pro'));
    await tester.pumpAndSettle();

    expect(services.analytics.pending.map((event) => event.name.wire), <String>[
      'paywall_viewed',
      'purchase_started',
      'purchase_completed',
    ]);
    await teardown(tester);
  });

  testWidgets('a purchase that fails is recorded with its reason', (
    tester,
  ) async {
    final services = await pumpPaywall(
      tester,
      purchases: MockPurchaseService(
        startProOutcome: const PurchaseFailed('Declined.'),
      ),
    );

    await tester.tap(find.text('Start Pro'));
    await tester.pump();
    await tester.pump();

    final failed = services.analytics.pending.last;
    expect(failed.name.wire, 'purchase_failed');
    expect(failed.properties, <String, Object?>{
      'product_id': 'pro.monthly',
      'reason': 'declined',
    });
    await teardown(tester);
  });
}
