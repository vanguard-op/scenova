import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/colors.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/widgets/app_icons.dart';

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
  group('glyph assets', () {
    test(
      'the active state uses the filled form, the rest the outlined form',
      () {
        const glyph = ScenovaGlyph.play;

        expect(
          glyph.assetPath(ScenovaIconState.active),
          'assets/icons/filled/play.svg',
        );
        expect(
          glyph.assetPath(ScenovaIconState.inactive),
          'assets/icons/outlined/play.svg',
        );
        // The disabled treatment is a tone change, not a different shape.
        expect(
          glyph.assetPath(ScenovaIconState.disabled),
          'assets/icons/outlined/play.svg',
        );
      },
    );

    test('every glyph in the custom set names a distinct asset', () {
      final names = ScenovaGlyph.values.map((glyph) => glyph.assetName);
      expect(names.toSet(), hasLength(ScenovaGlyph.values.length));
    });

    test('every glyph resolves through the bundled asset set', () async {
      // Guards the asset paths the screens depend on, including the outlined
      // form the default and disabled states share and the filled active form.
      for (final glyph in ScenovaGlyph.values) {
        for (final state in <ScenovaIconState>[
          ScenovaIconState.inactive,
          ScenovaIconState.active,
        ]) {
          final path = glyph.assetPath(state);
          final data = await rootBundle.load(path);
          expect(data.lengthInBytes, greaterThan(0), reason: path);
        }
      }
    });
  });

  group('AppIconView', () {
    testWidgets('renders a custom-set glyph from its asset', (tester) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.play));
      await tester.pumpAndSettle();

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('loads the outlined asset for the default state', (
      tester,
    ) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.history));
      await tester.pumpAndSettle();

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        svg.bytesLoader.toString(),
        contains('assets/icons/outlined/history.svg'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('takes the default state tone from text-secondary', (
      tester,
    ) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.seeIt));
      await tester.pumpAndSettle();

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        svg.colorFilter,
        ColorFilter.mode(ScenovaPalette.grey600Light, BlendMode.srcIn),
      );
    });

    testWidgets('takes the active state tone from the primary accent', (
      tester,
    ) async {
      await pumpIcon(
        tester,
        const AppIconView(
          icon: AppIcons.listen,
          state: ScenovaIconState.active,
        ),
      );
      await tester.pumpAndSettle();

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        svg.colorFilter,
        ColorFilter.mode(ScenovaPalette.primary500Light, BlendMode.srcIn),
      );
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
        const AppIconView(
          icon: AppIcons.save,
          state: ScenovaIconState.disabled,
        ),
      );
      await tester.pumpAndSettle();

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(
        svg.colorFilter,
        ColorFilter.mode(ScenovaPalette.grey400Light, BlendMode.srcIn),
      );
    });

    testWidgets('a caller tone overrides the state tone', (tester) async {
      await pumpIcon(
        tester,
        const AppIconView(icon: AppIcons.play, color: Colors.red),
      );
      await tester.pumpAndSettle();

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.colorFilter, ColorFilter.mode(Colors.red, BlendMode.srcIn));
    });

    testWidgets('a system icon renders as a platform Icon', (tester) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.search));
      await tester.pumpAndSettle();

      expect(find.byType(Icon), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
    });

    testWidgets('the default size follows the device class scale', (
      tester,
    ) async {
      await pumpIcon(tester, const AppIconView(icon: AppIcons.play));
      await tester.pumpAndSettle();

      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.width, ScenovaSizing.mobile.iconMd);
      expect(svg.height, ScenovaSizing.mobile.iconMd);
    });

    testWidgets('a screen-reader label is exposed only when asked for', (
      tester,
    ) async {
      await pumpIcon(
        tester,
        const AppIconView(icon: AppIcons.save, semanticLabel: 'Save this word'),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Save this word'), findsOneWidget);
    });
  });

  group('AppIcons', () {
    test('covers every glyph in the custom set', () {
      const set = <AppIcon>[
        AppIcons.seeIt,
        AppIcons.play,
        AppIcons.pause,
        AppIcons.replay,
        AppIcons.listen,
        AppIcons.save,
        AppIcons.report,
        AppIcons.history,
        AppIcons.settings,
      ];

      expect(set, everyElement(isA<GlyphIcon>()));
      expect(
        set.cast<GlyphIcon>().map((icon) => icon.glyph).toSet(),
        ScenovaGlyph.values.toSet(),
      );
    });
  });
}
