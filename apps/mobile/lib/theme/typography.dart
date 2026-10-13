import 'package:flutter/material.dart';

import 'tokens.dart';

/// Typography tokens.
///
/// Source of truth: `docs/Scenova/branding.md` — "Typography". The display
/// serif carries the brand on the few headings the product has; body text
/// stays on a neutral sans for legibility on a small card.
///
/// The family names below match the branding spec. Their font files are not
/// yet in the asset ledger, so a missing family falls back to the platform
/// default until the assets land; this is reported rather than worked around.
abstract final class ScenovaTypography {
  /// Display and headings.
  static const String displayFamily = 'Lora';
  static const List<String> displayFallback = <String>[
    'Georgia',
    'Times New Roman',
    'serif',
  ];

  /// Body text and labels.
  static const String bodyFamily = 'Inter';
  static const List<String> bodyFallback = <String>[
    'Roboto',
    'Helvetica',
    'Arial',
    'sans-serif',
  ];
}

/// The type scale resolved for one device class (branding → "Type Scale").
@immutable
class ScenovaTypeScale {
  const ScenovaTypeScale({
    required this.display,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.bodyLarge,
    required this.body,
    required this.bodySmall,
    required this.caption,
  });

  final double display;
  final double h1;
  final double h2;
  final double h3;
  final double bodyLarge;
  final double body;
  final double bodySmall;
  final double caption;

  static const mobile = ScenovaTypeScale(
    display: 26,
    h1: 22,
    h2: 19,
    h3: 17,
    bodyLarge: 16,
    body: 16,
    bodySmall: 14,
    caption: 12,
  );

  static const tablet = ScenovaTypeScale(
    display: 32,
    h1: 26,
    h2: 21,
    h3: 18,
    bodyLarge: 17,
    body: 16,
    bodySmall: 14,
    caption: 12,
  );

  static ScenovaTypeScale of(DeviceClass device) =>
      device.isTablet ? tablet : mobile;
}

/// The resolved text styles, keyed by the branding token name.
///
/// Read it with [ScenovaTextStyles.of]. The Material [TextTheme] is built from
/// the same styles so stock widgets inherit the scale.
@immutable
class ScenovaTextStyles extends ThemeExtension<ScenovaTextStyles> {
  const ScenovaTextStyles({
    required this.display,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.bodyLarge,
    required this.body,
    required this.bodySmall,
    required this.caption,
  });

  final TextStyle display;
  final TextStyle h1;
  final TextStyle h2;
  final TextStyle h3;
  final TextStyle bodyLarge;
  final TextStyle body;
  final TextStyle bodySmall;
  final TextStyle caption;

  static ScenovaTextStyles resolve(ScenovaTypeScale scale) {
    return ScenovaTextStyles(
      display: _display(scale.display, FontWeight.w700, 1.2),
      h1: _display(scale.h1, FontWeight.w700, 1.25),
      h2: _display(scale.h2, FontWeight.w600, 1.3),
      h3: _display(scale.h3, FontWeight.w600, 1.35),
      bodyLarge: _body(scale.bodyLarge, FontWeight.w400, 1.5),
      body: _body(scale.body, FontWeight.w400, 1.5),
      bodySmall: _body(scale.bodySmall, FontWeight.w400, 1.5),
      caption: _body(scale.caption, FontWeight.w500, 1.4),
    );
  }

  static TextStyle _display(double size, FontWeight weight, double height) {
    return TextStyle(
      fontFamily: ScenovaTypography.displayFamily,
      fontFamilyFallback: ScenovaTypography.displayFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
    );
  }

  static TextStyle _body(double size, FontWeight weight, double height) {
    return TextStyle(
      fontFamily: ScenovaTypography.bodyFamily,
      fontFamilyFallback: ScenovaTypography.bodyFallback,
      fontSize: size,
      fontWeight: weight,
      height: height,
    );
  }

  /// Maps the token scale onto Material's [TextTheme] slots so stock widgets
  /// (app bars, buttons, dialogs) inherit the brand scale.
  TextTheme toTextTheme() {
    return TextTheme(
      displayLarge: display,
      displayMedium: display,
      displaySmall: display,
      headlineLarge: h1,
      headlineMedium: h2,
      headlineSmall: h3,
      titleLarge: h2,
      titleMedium: h3,
      titleSmall: bodySmall.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: bodyLarge,
      bodyMedium: body,
      bodySmall: bodySmall,
      labelLarge: body.copyWith(fontWeight: FontWeight.w600),
      labelMedium: caption,
      labelSmall: caption,
    );
  }

  static ScenovaTextStyles of(BuildContext context) {
    final styles = Theme.of(context).extension<ScenovaTextStyles>();
    assert(
      styles != null,
      'ScenovaTextStyles is missing from the active theme.',
    );
    return styles!;
  }

  @override
  ScenovaTextStyles copyWith({
    TextStyle? display,
    TextStyle? h1,
    TextStyle? h2,
    TextStyle? h3,
    TextStyle? bodyLarge,
    TextStyle? body,
    TextStyle? bodySmall,
    TextStyle? caption,
  }) {
    return ScenovaTextStyles(
      display: display ?? this.display,
      h1: h1 ?? this.h1,
      h2: h2 ?? this.h2,
      h3: h3 ?? this.h3,
      bodyLarge: bodyLarge ?? this.bodyLarge,
      body: body ?? this.body,
      bodySmall: bodySmall ?? this.bodySmall,
      caption: caption ?? this.caption,
    );
  }

  @override
  ScenovaTextStyles lerp(ThemeExtension<ScenovaTextStyles>? other, double t) {
    if (other is! ScenovaTextStyles) return this;
    return t < 0.5 ? this : other;
  }
}
