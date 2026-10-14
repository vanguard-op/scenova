import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/theme/app_theme.dart';
import 'package:scenova_console/theme/colors.dart';
import 'package:scenova_console/theme/tokens.dart';
import 'package:scenova_console/theme/typography.dart';

void main() {
  // The brand-type test reads the bundled font files through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Desktop tokens', () {
    test('apply the branding doc\'s Desktop column', () {
      // The console is the doc's Desktop device class, so the device-keyed
      // scales are the Desktop values.
      expect(ScenovaSpacing.desktop.md, 16);
      expect(ScenovaSpacing.desktop.lg, 24);
      expect(ScenovaSpacing.desktop.xxxl, 64);

      expect(ScenovaSizing.desktop.buttonHeight, 40);
      expect(ScenovaSizing.desktop.inputHeight, 40);
      expect(ScenovaSizing.desktop.iconMd, 24);
      expect(ScenovaSizing.desktop.iconLg, 32);

      expect(ScenovaTypeScale.desktop.display, 34);
      expect(ScenovaTypeScale.desktop.h1, 28);
      expect(ScenovaTypeScale.desktop.h2, 22);
      expect(ScenovaTypeScale.desktop.h3, 18);
      expect(ScenovaTypeScale.desktop.bodyLarge, 17);
      expect(ScenovaTypeScale.desktop.body, 16);
      expect(ScenovaTypeScale.desktop.bodySmall, 14);
      expect(ScenovaTypeScale.desktop.caption, 12);
    });

    test('the console\'s controls clear the pointer minimum target', () {
      // branding.md → "Accessibility": the console's controls meet the 24x24px
      // minimum for pointer input.
      expect(ScenovaSizing.desktop.buttonHeight, greaterThanOrEqualTo(24));
      expect(ScenovaSizing.desktop.iconMd, greaterThanOrEqualTo(24));
    });
  });

  group('colour tokens', () {
    test('structural roles map onto the grey scale', () {
      expect(ScenovaColors.light.surface, ScenovaPalette.grey50Light);
      expect(ScenovaColors.light.textPrimary, ScenovaPalette.grey900Light);
      expect(ScenovaColors.light.border, ScenovaPalette.grey300Light);
      expect(ScenovaColors.dark.surface, ScenovaPalette.grey50Dark);
    });

    test('publishes the completed semantic shades', () {
      const light = ScenovaColors.light;
      expect(light.warning.element, ScenovaPalette.warning500Light);
      expect(light.warning.tint, ScenovaPalette.warning100Light);
      expect(light.warning.border, ScenovaPalette.warning300Light);
      expect(light.info.tint, ScenovaPalette.info100Light);
      expect(light.success.text, ScenovaPalette.success900Light);
      expect(light.error.element, ScenovaPalette.error500Light);
    });

    test('the semantic tints are solid shades', () {
      for (final colors in <ScenovaColors>[
        ScenovaColors.light,
        ScenovaColors.dark,
      ]) {
        for (final family in <ScenovaSemanticColors>[
          colors.success,
          colors.warning,
          colors.error,
          colors.info,
          colors.accent,
        ]) {
          expect(family.tint.a, 1.0);
        }
      }
    });

    test('the icon states follow the iconography direction', () {
      expect(ScenovaColors.light.iconDefault, ScenovaPalette.grey600Light);
      expect(ScenovaColors.light.iconActive, ScenovaPalette.primary500Light);
      expect(ScenovaColors.light.iconDisabled, ScenovaPalette.grey400Light);
      expect(ScenovaColors.dark.iconActive, ScenovaPalette.primary500Dark);
    });
  });

  group('AppTheme', () {
    test('exposes every token extension for each brightness', () {
      for (final brightness in Brightness.values) {
        final theme = AppTheme.build(brightness: brightness);
        final colors = theme.extension<ScenovaColors>();
        final styles = theme.extension<ScenovaTextStyles>();
        final tokens = theme.extension<ScenovaTokens>();

        expect(colors, isNotNull);
        expect(styles, isNotNull);
        expect(tokens, isNotNull);
        expect(tokens!.spacing.md, 16);
        expect(styles!.display.fontSize, 34);
        expect(theme.colorScheme.brightness, brightness);
        expect(theme.scaffoldBackgroundColor, colors!.surface);
      }
    });

    test('gives inputs a 2px focus ring in the primary colour', () {
      final theme = AppTheme.build(brightness: Brightness.light);
      final focused = theme.inputDecorationTheme.focusedBorder;
      expect(focused, isA<OutlineInputBorder>());
      expect((focused! as OutlineInputBorder).borderSide.width, 2);
      expect(
        (focused as OutlineInputBorder).borderSide.color,
        ScenovaPalette.primary500Light,
      );
    });
  });

  group('brand type', () {
    test('bundles the display and body families the styles name', () async {
      for (final asset in <String>[
        'assets/fonts/Lora[wght].ttf',
        'assets/fonts/Inter[opsz,wght].ttf',
      ]) {
        final data = await rootBundle.load(asset);
        expect(data.lengthInBytes, greaterThan(0), reason: asset);
      }
    });
  });
}
