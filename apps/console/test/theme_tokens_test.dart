import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/theme/app_theme.dart';
import 'package:scenova_design/scenova_design.dart';

void main() {
  // The brand-type test reads the bundled font files through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppTheme', () {
    test('resolves the branding doc\'s Desktop column', () {
      // The console is the doc's Desktop device class, so the device-keyed
      // scales are the Desktop values.
      final theme = AppTheme.build(brightness: Brightness.light);
      final tokens = theme.extension<ScenovaTokens>()!;
      final styles = theme.extension<ScenovaTextStyles>()!;

      expect(tokens.deviceClass, DeviceClass.desktop);
      expect(tokens.spacing.md, 16);
      expect(tokens.sizing.buttonHeight, 40);
      // Above the 24x24px minimum target for pointer input.
      expect(tokens.sizing.buttonHeight, greaterThanOrEqualTo(24));
      expect(styles.display.fontSize, 34);
    });

    test('exposes every token extension for each brightness', () {
      for (final brightness in Brightness.values) {
        final theme = AppTheme.build(brightness: brightness);
        final colors = theme.extension<ScenovaColors>();

        expect(colors, isNotNull);
        expect(theme.extension<ScenovaTextStyles>(), isNotNull);
        expect(theme.extension<ScenovaTokens>(), isNotNull);
        expect(theme.colorScheme.brightness, brightness);
        expect(theme.scaffoldBackgroundColor, colors!.surface);
      }
    });

    test('adds the console\'s own theme pieces', () {
      final theme = AppTheme.build(brightness: Brightness.light);
      // Dense inputs and the menu chrome the console's own surfaces draw.
      expect(theme.inputDecorationTheme.isDense, isTrue);
      expect(theme.tooltipTheme.decoration, isNotNull);
      expect(theme.dropdownMenuTheme.menuStyle, isNotNull);
      // Focus is carried by the brand's own ring, so the platform's focus fill
      // stays at its default rather than the full element colour.
      expect(theme.focusColor, isNot(ScenovaPalette.primary500Light));
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
