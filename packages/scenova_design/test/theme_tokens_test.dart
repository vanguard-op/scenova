import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_design/scenova_design.dart';

void main() {
  group('DeviceClass', () {
    test('resolves the doc\'s three classes at its breakpoints', () {
      // branding.md → "Responsive & Device Targets": mobile below 600px,
      // tablet from 600px, desktop from 1024px.
      expect(DeviceClass.fromWidth(599), DeviceClass.mobile);
      expect(DeviceClass.fromWidth(600), DeviceClass.tablet);
      expect(DeviceClass.fromWidth(1023), DeviceClass.tablet);
      expect(DeviceClass.fromWidth(1024), DeviceClass.desktop);
    });

    test('the reader app never takes the desktop posture', () {
      expect(DeviceClass.fromReaderWidth(400), DeviceClass.mobile);
      expect(DeviceClass.fromReaderWidth(800), DeviceClass.tablet);
      expect(DeviceClass.fromReaderWidth(1600), DeviceClass.tablet);
    });
  });

  group('device-keyed tokens', () {
    test('spacing overrides on tablet and holds on desktop', () {
      expect(ScenovaSpacing.of(DeviceClass.mobile).md, 12);
      expect(ScenovaSpacing.of(DeviceClass.tablet).md, 16);
      expect(ScenovaSpacing.of(DeviceClass.mobile).lg, 20);
      expect(ScenovaSpacing.of(DeviceClass.tablet).lg, 24);
      expect(ScenovaSpacing.of(DeviceClass.mobile).xxxl, 56);
      expect(ScenovaSpacing.of(DeviceClass.tablet).xxxl, 64);
      expect(ScenovaSpacing.of(DeviceClass.desktop).md, 16);
      expect(ScenovaSpacing.of(DeviceClass.desktop).xxxl, 64);
    });

    test('sizing carries each class\'s own column', () {
      expect(ScenovaSizing.of(DeviceClass.mobile).inputHeight, 48);
      expect(ScenovaSizing.of(DeviceClass.tablet).inputHeight, 44);
      expect(ScenovaSizing.of(DeviceClass.mobile).iconLg, 32);
      expect(ScenovaSizing.of(DeviceClass.tablet).iconLg, 40);
      // The button height is the minimum touch target on the reader's classes.
      expect(ScenovaSizing.of(DeviceClass.mobile).buttonHeight, 44);
      expect(ScenovaSizing.of(DeviceClass.tablet).buttonHeight, 44);
      // The console's Desktop column: the control height, above the 24px
      // minimum pointer target the console is held to.
      expect(ScenovaSizing.of(DeviceClass.desktop).buttonHeight, 40);
      expect(ScenovaSizing.of(DeviceClass.desktop).inputHeight, 40);
      expect(ScenovaSizing.of(DeviceClass.desktop).iconLg, 32);
    });

    test('type scale carries each class\'s own column', () {
      expect(ScenovaTypeScale.of(DeviceClass.mobile).display, 26);
      expect(ScenovaTypeScale.of(DeviceClass.tablet).display, 32);
      expect(ScenovaTypeScale.of(DeviceClass.desktop).display, 34);
      expect(ScenovaTypeScale.of(DeviceClass.mobile).h1, 22);
      expect(ScenovaTypeScale.of(DeviceClass.tablet).h1, 26);
      expect(ScenovaTypeScale.of(DeviceClass.desktop).h1, 28);
      expect(ScenovaTypeScale.of(DeviceClass.desktop).h3, 18);
      expect(ScenovaTypeScale.of(DeviceClass.desktop).bodyLarge, 17);
      // Body sizes hold across the classes.
      for (final device in DeviceClass.values) {
        expect(ScenovaTypeScale.of(device).body, 16);
        expect(ScenovaTypeScale.of(device).bodySmall, 14);
        expect(ScenovaTypeScale.of(device).caption, 12);
      }
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
        // The in-context card sits over a page the product does not own, so a
        // tint is a solid shade rather than the element colour at reduced
        // opacity.
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

    test('the icon states follow the iconography direction', () {
      // Default in text-secondary, active in primary-500, disabled in a solid
      // grey-400 that is dimmer than the default in both themes.
      const light = ScenovaColors.light;
      expect(light.iconDefault, ScenovaPalette.grey600Light);
      expect(light.iconActive, ScenovaPalette.primary500Light);
      expect(light.iconDisabled, ScenovaPalette.grey400Light);

      const dark = ScenovaColors.dark;
      expect(dark.iconDefault, ScenovaPalette.grey600Dark);
      expect(dark.iconActive, ScenovaPalette.primary500Dark);
      expect(dark.iconDisabled, ScenovaPalette.grey400Dark);
    });

    test('the placeholder role is the neutral scale\'s grey-600', () {
      // The neutral scale gives `grey-600` the placeholder role alongside
      // secondary text; `grey-400` is the disabled-icon shade.
      expect(ScenovaColors.light.placeholder, ScenovaPalette.grey600Light);
      expect(ScenovaColors.dark.placeholder, ScenovaPalette.grey600Dark);
    });

    test('on-solid flips from white in light to dark ink in dark', () {
      // `on-solid` is the exception to the shade mapping: the element shades
      // lighten in dark, so a fixed white would fall below the text target on
      // them. It carries its own pair of values rather than one shade.
      expect(ScenovaColors.light.onSolid, ScenovaPalette.onSolidLight);
      expect(ScenovaColors.dark.onSolid, ScenovaPalette.onSolidDark);
      expect(ScenovaPalette.onSolidLight, const Color(0xFFFFFFFF));
      expect(ScenovaPalette.onSolidDark, const Color(0xFF1A1820));
    });
  });

  group('contrast target', () {
    // branding.md → "Accessibility": WCAG 2.2 AA — 4.5:1 for normal text,
    // 3:1 for large text — and the semantic families carry their own text
    // shade so a note on a tinted surface holds.
    for (final brightness in Brightness.values) {
      final colors = ScenovaColors.resolve(brightness);

      test('body text clears 4.5:1 on the page surface ($brightness)', () {
        expect(
          _contrastRatio(colors.textPrimary, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrastRatio(colors.textSecondary, colors.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('hint text clears 4.5:1 on the input surface ($brightness)', () {
        expect(
          _contrastRatio(colors.placeholder, colors.surfaceSecondary),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('the icon states clear 3:1 on the page surface ($brightness)', () {
        // Icons are non-text content: the AA minimum is 3:1.
        expect(
          _contrastRatio(colors.iconDefault, colors.surface),
          greaterThanOrEqualTo(3),
        );
      });

      test('each semantic family\'s text holds on its own tint '
          '($brightness)', () {
        for (final family in <ScenovaSemanticColors>[
          colors.success,
          colors.warning,
          colors.error,
          colors.info,
          colors.accent,
        ]) {
          expect(
            _contrastRatio(family.text, family.tint),
            greaterThanOrEqualTo(4.5),
          );
        }
      });

      test('the solid actions\' labels hold 4.5:1 ($brightness)', () {
        // The button table gives both solid variants the `on-solid` ink:
        // Primary sits on `primary-500`, Destructive on `error-500`.
        expect(
          _contrastRatio(colors.onSolid, colors.primary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          _contrastRatio(colors.onSolid, colors.error.element),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  group('ScenovaTheme', () {
    test('exposes every token extension for each class and brightness', () {
      for (final device in DeviceClass.values) {
        for (final brightness in Brightness.values) {
          final theme = ScenovaTheme.build(
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
      final tablet = ScenovaTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.tablet,
      );
      expect(tablet.extension<ScenovaTokens>()!.spacing.md, 16);
      expect(tablet.extension<ScenovaTextStyles>()!.display.fontSize, 32);

      final desktop = ScenovaTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.desktop,
      );
      expect(desktop.extension<ScenovaTokens>()!.sizing.buttonHeight, 40);
      expect(desktop.extension<ScenovaTextStyles>()!.display.fontSize, 34);
    });

    test('gives inputs a 2px focus ring in the primary colour', () {
      final theme = ScenovaTheme.build(
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

    test('the switches add only the pieces the app asked for', () {
      final base = ScenovaTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.mobile,
      );
      expect(base.bottomSheetTheme.backgroundColor, isNull);
      expect(base.listTileTheme.textColor, isNull);
      expect(base.tooltipTheme.decoration, isNull);
      expect(base.inputDecorationTheme.isDense, isFalse);

      final reader = ScenovaTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.mobile,
        brandFocusColor: true,
        bottomSheet: true,
        listTile: true,
      );
      expect(reader.focusColor, ScenovaPalette.primary500Light);
      expect(
        reader.bottomSheetTheme.backgroundColor,
        ScenovaPalette.grey50Light,
      );
      expect(reader.listTileTheme.textColor, ScenovaPalette.grey900Light);

      final console = ScenovaTheme.build(
        brightness: Brightness.light,
        deviceClass: DeviceClass.desktop,
        denseInputs: true,
        tooltip: true,
        dropdownMenu: true,
      );
      expect(console.inputDecorationTheme.isDense, isTrue);
      expect(console.tooltipTheme.decoration, isNotNull);
      expect(console.dropdownMenuTheme.menuStyle, isNotNull);
      // The console leaves the platform's own focus fill alone: its controls
      // draw the brand ring instead.
      expect(console.focusColor, isNot(ScenovaPalette.primary500Light));
    });
  });
}

/// The WCAG 2.x contrast ratio between two opaque colours.
double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color color) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}
