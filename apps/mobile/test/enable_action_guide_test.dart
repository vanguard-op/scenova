import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/widgets/enable_action_guide.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// FEAT-002 edge case: when the action is not enabled, the reader is shown how
/// to enable it. The steps differ by platform — iOS uses the share sheet.
void main() {
  Future<void> pumpGuide(
    WidgetTester tester, {
    required TargetPlatform platform,
  }) {
    final theme = AppTheme.build(
      brightness: Brightness.light,
      deviceClass: DeviceClass.mobile,
    ).copyWith(platform: platform);
    return tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(body: EnableActionGuide()),
      ),
    );
  }

  testWidgets('shows the share-sheet steps on iOS', (tester) async {
    await pumpGuide(tester, platform: TargetPlatform.iOS);

    expect(find.text('Add Scenova to the share sheet'), findsOneWidget);
    expect(find.text('Swipe the app row and tap More.'), findsOneWidget);
    expect(find.text('Turn on Scenova, then tap Done.'), findsOneWidget);
    // The Android instruction does not appear on iOS.
    expect(find.text('Tap the three dots to see more actions.'), findsNothing);
  });

  testWidgets('shows the selection-menu steps on Android', (tester) async {
    await pumpGuide(tester, platform: TargetPlatform.android);

    expect(find.text('Turn on the Scenova action'), findsOneWidget);
    expect(
      find.text('Tap the three dots to see more actions.'),
      findsOneWidget,
    );
    expect(find.text('Swipe the app row and tap More.'), findsNothing);
  });

  testWidgets('Home shows the guide when the action is off', (tester) async {
    await pumpHarness(
      tester,
      settings: SettingsController()..actionEnabled = false,
    );
    await tester.pump();

    expect(find.byType(EnableActionGuide), findsOneWidget);
    await teardown(tester);
  });
}
