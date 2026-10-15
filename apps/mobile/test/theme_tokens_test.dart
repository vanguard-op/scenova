import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova_design/scenova_design.dart';

void main() {
  // The brand-type test reads the bundled font files through the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppTheme', () {
    test('exposes every token extension for each reader device class', () {
      for (final device in <DeviceClass>[
        DeviceClass.mobile,
        DeviceClass.tablet,
      ]) {
        for (final brightness in Brightness.values) {
          final theme = AppTheme.build(
            brightness: brightness,
            deviceClass: device,
          );
          final colors = theme.extension<ScenovaColors>();
          final styles = theme.extension<ScenovaTextStyles>();
          final tokens = theme.extension<ScenovaTokens>();

          expect(colors, isNotNull);
          expect(styles, isNotNull);
          expect(tokens, isNotNull);
          expect(tokens!.deviceClass, device);
          expect(theme.colorScheme.brightness, brightness);
          expect(theme.scaffoldBackgroundColor, colors!.surface);
        }
      }
    });

    test('carries the reader\'s device class through to the token set', () {
      final tablet = AppTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.tablet,
      );
      expect(tablet.extension<ScenovaTokens>()!.spacing.md, 16);
      expect(tablet.extension<ScenovaTextStyles>()!.display.fontSize, 32);
    });

    test('adds the reader app\'s own theme pieces', () {
      final theme = AppTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.mobile,
      );
      // The in-context card becomes a bottom sheet on tablet, the History
      // screen draws list rows, and the platform focus fill takes the brand
      // colour.
      expect(theme.focusColor, ScenovaPalette.primary500Light);
      expect(
        theme.bottomSheetTheme.backgroundColor,
        ScenovaPalette.grey50Light,
      );
      expect(theme.listTileTheme.textColor, ScenovaPalette.grey900Light);
    });

    test('gives inputs a 2px focus ring in the primary colour', () {
      final theme = AppTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.mobile,
      );
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
      // The styles resolve to Lora and Inter; a family that is named but not
      // bundled silently falls back to the platform's own type.
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
