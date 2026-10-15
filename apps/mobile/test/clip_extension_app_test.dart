import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/extension/clip_extension_app.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/extension_channel.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova_design/scenova_design.dart';

import 'support/harness.dart';

/// The clip view as the iOS share extension presents it (`FEAT-002`). These
/// cover the handoff paths that carry risk: a live selection, an empty one, and
/// the dismiss that returns the reader to the reading app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel host = MethodChannel(ExtensionChannel.channelName);
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(host, null));

  Future<void> pumpExtension(WidgetTester tester, ScenovaServices services) {
    return tester.pumpWidget(
      ClipExtensionApp(
        services: services,
        extensionChannel: ExtensionChannel(),
      ),
    );
  }

  testWidgets('a selection from the share sheet opens the clip view', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi());
    await pumpExtension(tester, services);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(
      find.text('a short clip that shows what the word means'),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('an empty selection shows the empty state and starts no lookup', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi());
    await pumpExtension(tester, services);

    await deliverCapture(tester, '   ');
    await tester.pump();
    await tester.pump();

    expect(find.text('Nothing to look up'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Back to Home'), findsNothing);
    await teardown(tester);
  });

  testWidgets('the extension presentation paints a transparent backdrop', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi());
    await pumpExtension(tester, services);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(scaffold.backgroundColor, ScenovaPalette.transparent);
    // History is an app destination the extension cannot open.
    expect(find.text('History'), findsNothing);
    await teardown(tester);
  });

  testWidgets('dismissing the clip view asks the extension to close', (
    tester,
  ) async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(host, (call) async {
      calls.add(call.method);
      return null;
    });

    final services = buildServices(api: MockLookupApi());
    await pumpExtension(tester, services);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();

    await tester.tap(findIcon(AppIcons.close));
    await tester.pump();

    expect(calls, contains(ExtensionChannel.methodDismiss));
    await teardown(tester);
  });

  testWidgets('a second selection updates the open view in place', (
    tester,
  ) async {
    final services = buildServices(api: MockLookupApi());
    await pumpExtension(tester, services);

    await deliverCapture(tester, 'come');
    await tester.pump();
    await tester.pump();
    expect(find.byType(ClipViewScreen), findsOneWidget);

    await deliverCapture(tester, 'bank');
    await tester.pump();
    await tester.pump();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(find.text('Which meaning fits here?'), findsOneWidget);
    await teardown(tester);
  });
}
