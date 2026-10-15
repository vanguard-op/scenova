import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/config.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/report.dart';
import 'package:scenova/services/account_api.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/clip_store.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/poster_frame_store.dart';
import 'package:scenova/services/report_store.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/screens/preferences_screen.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

void main() {
  testWidgets('the rows are shown once the device history is read', (
    tester,
  ) async {
    await pumpPreferences(
      tester,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
      ),
    );
    await tester.pump();

    expect(find.text('Sound'), findsOneWidget);
    expect(find.text('Reduce motion'), findsOneWidget);
    expect(find.text('Look up new words'), findsOneWidget);
    expect(find.text('Selection label language'), findsOneWidget);
    expect(find.text('Clear history'), findsOneWidget);
    expect(find.text('Version ${AppConfig.appVersion}'), findsOneWidget);
    expect(find.text('1 saved lookup on this device.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the rows hold their place while the history is read', (
    tester,
  ) async {
    final history = DelayedHistoryStore();
    await pumpPreferences(tester, history: history);

    expect(find.byType(SkeletonList), findsOneWidget);

    history.completer.complete(<HistoryEntry>[]);
    await tester.pump();
    expect(find.byType(SkeletonList), findsNothing);
    expect(find.text('Sound'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a fresh install opens with sound off and consent on', (
    tester,
  ) async {
    await pumpPreferences(tester);
    await tester.pump();

    expect(_switch(tester, 'Sound').value, isFalse);
    expect(_switch(tester, 'Look up new words').value, isTrue);
    await teardown(tester);
  });

  testWidgets('turning sound on writes the setting at once', (tester) async {
    final services = await pumpPreferences(tester);
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Sound'));
    await tester.pump();

    expect(services.settings.soundOn, isTrue);
    expect(_switch(tester, 'Sound').value, isTrue);
    await teardown(tester);
  });

  testWidgets('the reader can reduce motion themselves', (tester) async {
    final services = await pumpPreferences(tester);
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Reduce motion'));
    await tester.pump();

    expect(services.settings.reduceMotionOverride, isTrue);
    expect(services.settings.reduceMotion, isTrue);
    await teardown(tester);
  });

  testWidgets('the device reduce-motion setting overrides the app preference', (
    tester,
  ) async {
    final settings = SettingsController()
      ..platformReduceMotion = true
      ..reduceMotionOverride = false;
    await pumpPreferences(tester, settings: settings);
    await tester.pump();

    final row = _switch(tester, 'Reduce motion');
    expect(row.value, isTrue);
    expect(row.onChanged, isNull);
    expect(
      find.text('Your device\'s reduce-motion setting is on.'),
      findsOneWidget,
    );
    // The reader's own choice cannot turn the platform's setting back up.
    expect(settings.reduceMotion, isTrue);
    await teardown(tester);
  });

  testWidgets('consent applies at once and is stored on the device', (
    tester,
  ) async {
    final services = await pumpPreferences(tester);
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Look up new words'));
    await tester.pump();

    expect(services.settings.consentModelProcessing, isFalse);
    await teardown(tester);
  });

  testWidgets('a signed-out reader\'s consent stays on the device', (
    tester,
  ) async {
    final accountApi = MockAccountApi();
    final services = await pumpPreferences(tester, accountApi: accountApi);
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Look up new words'));
    await tester.pump();

    expect(services.settings.consentModelProcessing, isFalse);
    expect(accountApi.writes, isEmpty);
    await teardown(tester);
  });

  testWidgets('a signed-in reader\'s consent reaches their account (C-020)', (
    tester,
  ) async {
    final accountApi = MockAccountApi();
    final services = await pumpPreferences(
      tester,
      accountApi: accountApi,
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Look up new words'));
    await tester.pump();

    expect(services.settings.consentModelProcessing, isFalse);
    expect(accountApi.writes, hasLength(1));
    expect(accountApi.writes.single.consentModelProcessing, isFalse);
    expect(find.textContaining('Saved on this device'), findsNothing);
    await teardown(tester);
  });

  testWidgets('an unreachable account keeps the choice and offers a retry', (
    tester,
  ) async {
    final accountApi = MockAccountApi(
      error: const AccountApiException(
        503,
        'Your account is unavailable right now.',
      ),
    );
    final services = await pumpPreferences(
      tester,
      accountApi: accountApi,
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(SwitchListTile, 'Look up new words'));
    await tester.pump();

    // The choice is in effect and stored, and the reader is told the account
    // has not taken it yet.
    expect(services.settings.consentModelProcessing, isFalse);
    expect(
      find.text('Saved on this device. Your account could not be reached.'),
      findsOneWidget,
    );

    accountApi.error = null;
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(accountApi.writes, hasLength(1));
    expect(find.textContaining('Saved on this device'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a language without a translation falls back to English', (
    tester,
  ) async {
    final services = await pumpPreferences(tester);
    await tester.pump();

    expect(
      find.text('Shown in English until this language is ready.'),
      findsNothing,
    );

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portuguese').last);
    await tester.pumpAndSettle();

    expect(services.settings.actionLabelLocale, 'pt');
    expect(
      find.text('Shown in English until this language is ready.'),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('a signed-in reader\'s language reaches their account (C-020)', (
    tester,
  ) async {
    final accountApi = MockAccountApi();
    await pumpPreferences(
      tester,
      accountApi: accountApi,
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    await tester.pump();

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('French').last);
    await tester.pumpAndSettle();

    expect(accountApi.writes.single.locale, 'fr');
    await teardown(tester);
  });

  testWidgets('the clear warns, and confirming removes the device copy', (
    tester,
  ) async {
    final history = InMemoryHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    final clips = InMemoryClipStore(
      seed: <String, String>{'k': 'file:///clip'},
    );
    final posters = InMemoryPosterFrameStore(
      seed: <String, Uint8List>{
        'k': Uint8List.fromList(<int>[1, 2]),
      },
    );
    final reports = InMemoryPendingReportStore(
      seed: <PendingReport>[
        PendingReport(
          lookupId: 'lookup-1',
          reason: ReportReason.wrongMeaning,
          clientReportId: 'report-1',
          createdAt: DateTime.utc(2026, 10, 15),
        ),
      ],
    );
    final services = buildServices(
      history: history,
      clips: clips,
      posterFrames: posters,
      reportStore: reports,
    );
    await tester.pumpWidget(
      ScenovaScope(
        services: services,
        child: MaterialApp(
          theme: AppTheme.build(
            brightness: Brightness.light,
            deviceClass: DeviceClass.mobile,
          ),
          home: const PreferencesScreen(),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();

    expect(find.text('Clear all history?'), findsOneWidget);
    expect(
      find.text(
        'This removes every saved lookup and its clip from this device. It '
        'cannot be undone.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(await history.all(), isEmpty);
    expect(await clips.source('k'), isNull);
    expect(await posters.frame('k'), isNull);
    // A report still waiting for a connection is not history, so it stays.
    expect(await reports.load(), hasLength(1));
    expect(find.text('No saved lookups on this device.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('keeping the history leaves it in place', (tester) async {
    final history = InMemoryHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    await pumpPreferences(tester, history: history);
    await tester.pump();

    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    expect(await history.all(), hasLength(1));
    expect(find.text('1 saved lookup on this device.'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('clearing history while offline removes the device copy', (
    tester,
  ) async {
    final history = InMemoryHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    await pumpPreferences(tester, history: history, online: false);
    await tester.pump();

    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(await history.all(), isEmpty);
    await teardown(tester);
  });

  testWidgets('the dialog shows progress while the history is cleared', (
    tester,
  ) async {
    final history = _SlowClearHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    await pumpPreferences(tester, history: history);
    await tester.pump();

    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pump();

    expect(find.text('Clearing history…'), findsOneWidget);
    expect(find.text('Clear'), findsNothing);
    // The clear row carries its own spinner behind the dialog
    // (`docs/Scenova/screens/07-preferences.md` → "Clearing history").
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'Clear history'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await teardown(tester);
  });
}

/// The switch row whose label is [label].
SwitchListTile _switch(WidgetTester tester, String label) =>
    tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, label));

/// A history whose clear resolves only when the test completes it, so the
/// clearing state can be looked at.
class _SlowClearHistoryStore extends InMemoryHistoryStore {
  _SlowClearHistoryStore({super.seed});

  final Completer<void> cleared = Completer<void>();

  @override
  Future<void> clear() => cleared.future;
}
