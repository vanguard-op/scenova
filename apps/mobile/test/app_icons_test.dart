import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova_design/scenova_design.dart';

/// Puts an icon under the real theme, so its tokens resolve the way they do in
/// the app.
Future<void> pumpIcon(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.mobile,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('AppIconView', () {
    testWidgets('draws from the platform pack, never from an asset', (
      tester,
    ) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.play));
      await tester.pumpAndSettle();

      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('takes the default tone from text-secondary', (tester) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.seeIt));
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, ScenovaPalette.grey600Light);
    });

    testWidgets('takes the active tone from the primary accent', (
      tester,
    ) async {
      await pumpIcon(
        tester,
        const AppIconView(icon: AppIcons.listen, active: true),
      );
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, ScenovaPalette.primary500Light);
    });

    testWidgets('the disabled tone is a solid grey-400, never an opacity', (
      tester,
    ) async {
      // D-014: the muted state reads through brightness, not alpha.
      expect(ScenovaColors.light.iconDisabled, ScenovaPalette.grey400Light);
      expect(ScenovaColors.light.iconDisabled.a, 1.0);
      expect(ScenovaColors.dark.iconDisabled, ScenovaPalette.grey400Dark);
      expect(ScenovaColors.dark.iconDisabled.a, 1.0);

      await pumpIcon(
        tester,
        const AppIconView(icon: AppIcons.report, enabled: false),
      );
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, ScenovaPalette.grey400Light);
    });

    testWidgets('a caller tone overrides the state tone', (tester) async {
      await pumpIcon(
        tester,
        const AppIconView(icon: AppIcons.play, color: Colors.red),
      );
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, Colors.red);
    });

    testWidgets('the default size follows the device class scale', (
      tester,
    ) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.play));
      await tester.pumpAndSettle();

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, ScenovaSizing.mobile.iconMd);
    });

    testWidgets('a screen-reader label is exposed only when asked for', (
      tester,
    ) async {
      await pumpIcon(
        tester,
        const AppIconView(icon: AppIcons.helpful, semanticLabel: 'Helpful'),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Helpful'), findsOneWidget);
    });
  });

  group('AppIcons', () {
    test('every icon the product draws belongs to the platform pack', () {
      // The product's own actions and the chrome around them come from the
      // platform's icon font; an icon pulled from a custom font or a bundled
      // asset would not resolve here.
      const drawn = <IconData>[
        AppIcons.seeIt,
        AppIcons.play,
        AppIcons.pause,
        AppIcons.replay,
        AppIcons.listen,
        AppIcons.mute,
        AppIcons.report,
        AppIcons.history,
        AppIcons.settings,
        AppIcons.more,
        AppIcons.helpful,
        AppIcons.notHelpful,
        AppIcons.offline,
        AppIcons.retry,
      ];

      for (final icon in drawn) {
        expect(icon.fontFamily, 'MaterialIcons', reason: '$icon');
        expect(icon.fontPackage, isNull, reason: '$icon');
        expect(icon.codePoint, greaterThan(0), reason: '$icon');
      }
    });
  });
}
