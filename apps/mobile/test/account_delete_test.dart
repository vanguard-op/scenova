import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/services/account_api.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/clip_store.dart';
import 'package:scenova/services/entitlement_api.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:scenova/widgets/delete_account_dialog.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// The Free plan a signed-in reader sees.
const Entitlement _free = Entitlement(
  tier: PlanTier.free,
  signedIn: true,
  lookupsUsed: 12,
  lookupsLimit: 20,
);

/// The Pro plan, a plan the store granted.
const Entitlement _pro = Entitlement(
  tier: PlanTier.pro,
  signedIn: true,
  lookupsUsed: 8,
  lookupsLimit: 50,
);

/// The confirmation's own destructive action, scoped to the dialog so the row
/// on the screen behind it is never the one tapped.
Finder _confirmAction(String label) => find.descendant(
  of: find.byType(DeleteAccountDialog),
  matching: find.widgetWithText(ScenovaButton, label),
);

void main() {
  testWidgets('the delete row opens a confirmation that says what changes', (
    tester,
  ) async {
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    await tester.pump();

    expect(find.text('Delete account'), findsOneWidget);

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(find.byType(DeleteAccountDialog), findsOneWidget);
    expect(find.text('Delete your account?'), findsOneWidget);
    expect(
      find.textContaining('the lookups saved on this device are cleared'),
      findsOneWidget,
    );
    expect(find.textContaining('shared library stay'), findsOneWidget);
    expect(_confirmAction('Keep my account'), findsOneWidget);
    expect(_confirmAction('Delete account'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets(
    'confirming deletes the account, clears the device history, and signs out',
    (tester) async {
      final api = MockAccountApi();
      final session = DevelopmentAccountSession(signedIn: true);
      final history = InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(word: 'come', phrase: 'to move towards someone'),
        ],
      );
      final clips = InMemoryClipStore(
        seed: <String, String>{'seed-come': 'file:///clips/come.mp4'},
      );
      final posters = InMemoryPosterFrameStore(
        seed: <String, Uint8List>{'seed-come': testPosterFrame()},
      );
      await pumpAccount(
        tester,
        entitlementsApi: MockEntitlementApi(plan: _free),
        accountSession: session,
        accountApi: api,
        history: history,
        clips: clips,
        posterFrames: posters,
      );
      await tester.pump();

      expect(await history.all(), hasLength(1));
      expect(await clips.source('seed-come'), isNotNull);
      expect(await posters.frame('seed-come'), isNotNull);

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(_confirmAction('Delete account'));
      await tester.pumpAndSettle();

      expect(api.deletions, 1);
      expect(session.signOutCalls, 1);
      // The device's own copy of the reader's lookups is gone.
      expect(await history.all(), isEmpty);
      expect(await clips.source('seed-come'), isNull);
      expect(await posters.frame('seed-come'), isNull);
      // The reader is returned to the signed-out state.
      expect(find.byType(DeleteAccountDialog), findsNothing);
      expect(find.text('Sign in to Scenova'), findsOneWidget);
      await teardown(tester);
    },
  );

  testWidgets('a reader the store bills is told to cancel it there', (
    tester,
  ) async {
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _pro),
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    await tester.pump();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Billing continues through the store'),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('a free reader is not told about a subscription', (tester) async {
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    await tester.pump();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Billing continues'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a deletion in flight shows progress and disables its controls', (
    tester,
  ) async {
    final api = _DelayedAccountApi();
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      accountSession: DevelopmentAccountSession(signedIn: true),
      accountApi: api,
    );
    await tester.pump();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(_confirmAction('Delete account'));
    await tester.pump();

    expect(find.text('Deleting your account…'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DeleteAccountDialog),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    // The controls are gone while the deletion runs, so it cannot be resolved
    // twice or abandoned mid-flight.
    expect(
      find.descendant(
        of: find.byType(DeleteAccountDialog),
        matching: find.byType(ScenovaButton),
      ),
      findsNothing,
    );

    api.completer.complete(true);
    await tester.pumpAndSettle();
    await teardown(tester);
  });

  testWidgets(
    'a deletion that did not complete keeps the account and retries',
    (tester) async {
      final api = MockAccountApi(
        error: const AccountApiException(503, 'Your account is unavailable.'),
      );
      final session = DevelopmentAccountSession(signedIn: true);
      await pumpAccount(
        tester,
        entitlementsApi: MockEntitlementApi(plan: _free),
        accountSession: session,
        accountApi: api,
      );
      await tester.pump();

      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(_confirmAction('Delete account'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Your account could not be deleted. Check your connection and try '
          'again.',
        ),
        findsOneWidget,
      );
      // The account is unchanged and the reader is still on their plan.
      expect(api.deletions, 0);
      expect(session.signOutCalls, 0);
      expect(find.text('Free'), findsOneWidget);
      expect(find.byType(DeleteAccountDialog), findsOneWidget);

      // The connection returns and the reader retries.
      api.error = null;
      await tester.tap(_confirmAction('Try again'));
      await tester.pumpAndSettle();

      expect(api.deletions, 1);
      expect(session.signOutCalls, 1);
      expect(find.text('Sign in to Scenova'), findsOneWidget);
      await teardown(tester);
    },
  );

  testWidgets('keeping the account leaves everything unchanged', (
    tester,
  ) async {
    final api = MockAccountApi();
    final session = DevelopmentAccountSession(signedIn: true);
    final history = InMemoryHistoryStore(
      seed: <HistoryEntry>[
        seededEntry(word: 'come', phrase: 'to move towards someone'),
      ],
    );
    await pumpAccount(
      tester,
      entitlementsApi: MockEntitlementApi(plan: _free),
      accountSession: session,
      accountApi: api,
      history: history,
    );
    await tester.pump();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(_confirmAction('Keep my account'));
    await tester.pumpAndSettle();

    expect(find.byType(DeleteAccountDialog), findsNothing);
    expect(api.deletions, 0);
    expect(session.signOutCalls, 0);
    expect(await history.all(), hasLength(1));
    expect(find.text('Free'), findsOneWidget);
    await teardown(tester);
  });
}

/// An account store whose deletion resolves only when the test completes it,
/// for the in-flight state.
class _DelayedAccountApi implements AccountApi {
  final Completer<bool> completer = Completer<bool>();

  @override
  Future<AccountPreferences> update({
    bool? consentModelProcessing,
    String? locale,
  }) async =>
      const AccountPreferences(consentModelProcessing: true, locale: 'en');

  @override
  Future<AccountPreferences> read() async =>
      const AccountPreferences(consentModelProcessing: true, locale: 'en');

  @override
  Future<bool> deleteAccount() => completer.future;
}
