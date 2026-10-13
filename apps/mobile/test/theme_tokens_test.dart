import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/colors.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/theme/typography.dart';

void main() {
  group('DeviceClass', () {
    test('switches at the 600px breakpoint', () {
      expect(DeviceClass.fromWidth(599), DeviceClass.mobile);
      expect(DeviceClass.fromWidth(600), DeviceClass.tablet);
      expect(DeviceClass.fromWidth(1024), DeviceClass.tablet);
    });
  });

  group('device-keyed tokens', () {
    test('spacing overrides on tablet', () {
      expect(ScenovaSpacing.of(DeviceClass.mobile).md, 12);
      expect(ScenovaSpacing.of(DeviceClass.tablet).md, 16);
      expect(ScenovaSpacing.of(DeviceClass.mobile).lg, 20);
      expect(ScenovaSpacing.of(DeviceClass.tablet).lg, 24);
      expect(ScenovaSpacing.of(DeviceClass.mobile).xxxl, 56);
      expect(ScenovaSpacing.of(DeviceClass.tablet).xxxl, 64);
    });

    test('sizing overrides on tablet', () {
      expect(ScenovaSizing.of(DeviceClass.mobile).inputHeight, 48);
      expect(ScenovaSizing.of(DeviceClass.tablet).inputHeight, 44);
      expect(ScenovaSizing.of(DeviceClass.mobile).iconLg, 32);
      expect(ScenovaSizing.of(DeviceClass.tablet).iconLg, 40);
      // The button height is the minimum touch target on both classes.
      expect(ScenovaSizing.of(DeviceClass.mobile).buttonHeight, 44);
      expect(ScenovaSizing.of(DeviceClass.tablet).buttonHeight, 44);
    });

    test('type scale overrides on tablet', () {
      expect(ScenovaTypeScale.of(DeviceClass.mobile).display, 26);
      expect(ScenovaTypeScale.of(DeviceClass.tablet).display, 32);
      expect(ScenovaTypeScale.of(DeviceClass.mobile).h1, 22);
      expect(ScenovaTypeScale.of(DeviceClass.tablet).h1, 26);
      // Body sizes hold across classes.
      expect(ScenovaTypeScale.of(DeviceClass.mobile).body, 16);
      expect(ScenovaTypeScale.of(DeviceClass.tablet).body, 16);
    });
  });

  group('colour tokens', () {
    test('structural roles map onto the grey scale', () {
      expect(ScenovaColors.light.surface, ScenovaPalette.grey50Light);
      expect(ScenovaColors.light.textPrimary, ScenovaPalette.grey900Light);
      expect(ScenovaColors.light.border, ScenovaPalette.grey300Light);
      expect(ScenovaColors.dark.surface, ScenovaPalette.grey50Dark);
      expect(ScenovaColors.dark.textPrimary, ScenovaPalette.grey900Dark);
    });

    test('resolves by brightness', () {
      expect(ScenovaColors.resolve(Brightness.dark), ScenovaColors.dark);
      expect(ScenovaColors.resolve(Brightness.light), ScenovaColors.light);
    });

    test('publishes the completed 100/300/500/700/900 semantic shades', () {
      const light = ScenovaColors.light;
      expect(light.warning.element, ScenovaPalette.warning500Light);
      expect(light.warning.tint, ScenovaPalette.warning100Light);
      expect(light.warning.border, ScenovaPalette.warning300Light);
      expect(light.warning.pressed, ScenovaPalette.warning700Light);
      expect(light.warning.text, ScenovaPalette.warning900Light);

      expect(light.error.element, ScenovaPalette.error500Light);
      expect(light.error.tint, ScenovaPalette.error100Light);
      expect(light.error.border, ScenovaPalette.error300Light);
      expect(light.error.pressed, ScenovaPalette.error700Light);
      expect(light.error.text, ScenovaPalette.error900Light);

      expect(light.info.tint, ScenovaPalette.info100Light);
      expect(light.accent.element, ScenovaPalette.accent500Light);
      expect(light.success.text, ScenovaPalette.success900Light);

      const dark = ScenovaColors.dark;
      expect(dark.warning.tint, ScenovaPalette.warning100Dark);
      expect(dark.error.text, ScenovaPalette.error900Dark);
      expect(dark.info.border, ScenovaPalette.info300Dark);
      expect(dark.accent.pressed, ScenovaPalette.accent700Dark);
      expect(dark.success.element, ScenovaPalette.success500Dark);
    });

    test(
      'the semantic tints are solid shades, not alpha over an unknown surface',
      () {
        // The in-context card sits over a page the product does not own, so a tint
        // is a solid shade rather than the element colour at reduced opacity.
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
      },
    );

    test('builds a colour scheme from the palette', () {
      final scheme = ScenovaColors.light.toColorScheme(Brightness.light);
      expect(scheme.primary, ScenovaPalette.primary500Light);
      expect(scheme.surface, ScenovaPalette.grey50Light);
    });
  });

  group('AppTheme', () {
    test('exposes every token extension for each device class', () {
      for (final device in DeviceClass.values) {
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

    test('carries the device class through to the token set', () {
      final tablet = AppTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.tablet,
      );
      expect(tablet.extension<ScenovaTokens>()!.spacing.md, 16);
      expect(tablet.extension<ScenovaTextStyles>()!.display.fontSize, 32);
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
}
