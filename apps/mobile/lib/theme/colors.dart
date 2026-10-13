import 'package:flutter/material.dart';

/// Colour tokens for Scenova.
///
/// Source of truth: `docs/Scenova/branding.md` — "Color Palette". Every colour
/// in the app resolves through this file; no widget carries a literal colour.
///
/// The palette publishes the 500 shade for each accent and semantic family but
/// not the 100 and 900 shades it names; the tint tokens below are that 500
/// shade at a fixed alpha so the family still reads as a tinted background.
/// This is reported as a gap in the branding spec.
abstract final class ScenovaPalette {
  // Primary — a 9-shade scale.
  static const Color primary900Light = Color(0xFF221B54);
  static const Color primary900Dark = Color(0xFFDCD6FB);
  static const Color primary800Light = Color(0xFF2E2470);
  static const Color primary800Dark = Color(0xFFC7BFF7);
  static const Color primary700Light = Color(0xFF3B2E8C);
  static const Color primary700Dark = Color(0xFFB0A6F2);
  static const Color primary600Light = Color(0xFF4B3BA8);
  static const Color primary600Dark = Color(0xFF9A8EEC);
  static const Color primary500Light = Color(0xFF5C4BC4);
  static const Color primary500Dark = Color(0xFF8578E4);
  static const Color primary400Light = Color(0xFF7E70D4);
  static const Color primary400Dark = Color(0xFF6A5DCB);
  static const Color primary300Light = Color(0xFFA79CE3);
  static const Color primary300Dark = Color(0xFF5247A6);
  static const Color primary200Light = Color(0xFFCBC4F0);
  static const Color primary200Dark = Color(0xFF3C3480);
  static const Color primary100Light = Color(0xFFEEEBFA);
  static const Color primary100Dark = Color(0xFF262151);

  // Neutral — grey 900 to 50.
  static const Color grey900Light = Color(0xFF1A1820);
  static const Color grey900Dark = Color(0xFFF4F3F7);
  static const Color grey800Light = Color(0xFF2A2733);
  static const Color grey800Dark = Color(0xFFE3E1E9);
  static const Color grey700Light = Color(0xFF3A3745);
  static const Color grey700Dark = Color(0xFFC9C6D2);
  static const Color grey600Light = Color(0xFF504C5C);
  static const Color grey600Dark = Color(0xFFA7A3B2);
  static const Color grey500Light = Color(0xFF6B6775);
  static const Color grey500Dark = Color(0xFF85808F);
  static const Color grey400Light = Color(0xFF8C8896);
  static const Color grey400Dark = Color(0xFF625E6C);
  static const Color grey300Light = Color(0xFFB6B3BE);
  static const Color grey300Dark = Color(0xFF47434F);
  static const Color grey200Light = Color(0xFFD6D4DB);
  static const Color grey200Dark = Color(0xFF33303A);
  static const Color grey100Light = Color(0xFFECEBEF);
  static const Color grey100Dark = Color(0xFF26242C);
  static const Color grey50Light = Color(0xFFF7F6F9);
  static const Color grey50Dark = Color(0xFF1B1A20);

  // Accent and semantic families — the 500 shade is the element colour.
  static const Color success500Light = Color(0xFF2E9E6B);
  static const Color success500Dark = Color(0xFF57C48D);
  static const Color warning500Light = Color(0xFFC9541B);
  static const Color warning500Dark = Color(0xFFDE7B42);
  static const Color error500Light = Color(0xFFC43B3B);
  static const Color error500Dark = Color(0xFFDE6A6A);
  static const Color info500Light = Color(0xFF3C7DD9);
  static const Color info500Dark = Color(0xFF6BA0E8);
  static const Color accent500Light = Color(0xFFC99A2E);
  static const Color accent500Dark = Color(0xFFE4BE5C);

  /// White, used for text on filled primary and destructive surfaces.
  static const Color onFill = Color(0xFFFFFFFF);

  /// No colour; used for outline and ghost surfaces.
  static const Color transparent = Color(0x00000000);
}

/// Semantic colour tokens resolved for one brightness.
///
/// Read it with [ScenovaColors.of].
@immutable
class ScenovaColors extends ThemeExtension<ScenovaColors> {
  const ScenovaColors({
    required this.surface,
    required this.surfaceSecondary,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.placeholder,
    required this.border,
    required this.iconDefault,
    required this.iconActive,
    required this.iconDisabled,
    required this.primary,
    required this.onPrimary,
    required this.primaryTint,
    required this.primaryDeep,
    required this.primaryPressed,
    required this.focusRing,
    required this.success,
    required this.successTint,
    required this.warning,
    required this.warningTint,
    required this.error,
    required this.errorTint,
    required this.info,
    required this.infoTint,
    required this.accent,
    required this.accentTint,
    required this.onFill,
  });

  final Color surface;
  final Color surfaceSecondary;
  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;
  final Color placeholder;
  final Color border;
  final Color iconDefault;
  final Color iconActive;
  final Color iconDisabled;
  final Color primary;
  final Color onPrimary;
  final Color primaryTint;
  final Color primaryDeep;
  final Color primaryPressed;
  final Color focusRing;
  final Color success;
  final Color successTint;
  final Color warning;
  final Color warningTint;
  final Color error;
  final Color errorTint;
  final Color info;
  final Color infoTint;
  final Color accent;
  final Color accentTint;
  final Color onFill;

  static const ScenovaColors light = ScenovaColors(
    surface: ScenovaPalette.grey50Light,
    surfaceSecondary: ScenovaPalette.grey100Light,
    textPrimary: ScenovaPalette.grey900Light,
    textSecondary: ScenovaPalette.grey600Light,
    textDisabled: ScenovaPalette.grey500Light,
    placeholder: ScenovaPalette.grey400Light,
    border: ScenovaPalette.grey300Light,
    iconDefault: ScenovaPalette.grey700Light,
    iconActive: ScenovaPalette.primary500Light,
    iconDisabled: ScenovaPalette.grey400Light,
    primary: ScenovaPalette.primary500Light,
    onPrimary: ScenovaPalette.onFill,
    primaryTint: ScenovaPalette.primary100Light,
    primaryDeep: ScenovaPalette.primary700Light,
    primaryPressed: ScenovaPalette.primary600Light,
    focusRing: ScenovaPalette.primary500Light,
    success: ScenovaPalette.success500Light,
    successTint: Color(0x1F2E9E6B),
    warning: ScenovaPalette.warning500Light,
    warningTint: Color(0x1FC9541B),
    error: ScenovaPalette.error500Light,
    errorTint: Color(0x1FC43B3B),
    info: ScenovaPalette.info500Light,
    infoTint: Color(0x1F3C7DD9),
    accent: ScenovaPalette.accent500Light,
    accentTint: Color(0x1FC99A2E),
    onFill: ScenovaPalette.onFill,
  );

  static const ScenovaColors dark = ScenovaColors(
    surface: ScenovaPalette.grey50Dark,
    surfaceSecondary: ScenovaPalette.grey100Dark,
    textPrimary: ScenovaPalette.grey900Dark,
    textSecondary: ScenovaPalette.grey600Dark,
    textDisabled: ScenovaPalette.grey500Dark,
    placeholder: ScenovaPalette.grey400Dark,
    border: ScenovaPalette.grey300Dark,
    iconDefault: ScenovaPalette.grey700Dark,
    iconActive: ScenovaPalette.primary500Dark,
    iconDisabled: ScenovaPalette.grey400Dark,
    primary: ScenovaPalette.primary500Dark,
    onPrimary: ScenovaPalette.grey50Dark,
    primaryTint: ScenovaPalette.primary100Dark,
    primaryDeep: ScenovaPalette.primary700Dark,
    primaryPressed: ScenovaPalette.primary600Dark,
    focusRing: ScenovaPalette.primary500Dark,
    success: ScenovaPalette.success500Dark,
    successTint: Color(0x3357C48D),
    warning: ScenovaPalette.warning500Dark,
    warningTint: Color(0x33DE7B42),
    error: ScenovaPalette.error500Dark,
    errorTint: Color(0x33DE6A6A),
    info: ScenovaPalette.info500Dark,
    infoTint: Color(0x336BA0E8),
    accent: ScenovaPalette.accent500Dark,
    accentTint: Color(0x33E4BE5C),
    onFill: ScenovaPalette.onFill,
  );

  static ScenovaColors of(BuildContext context) {
    final colors = Theme.of(context).extension<ScenovaColors>();
    assert(colors != null, 'ScenovaColors is missing from the active theme.');
    return colors!;
  }

  static ScenovaColors resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The Material [ColorScheme] the palette maps onto, so stock widgets
  /// (dialogs, snack bars, progress indicators) inherit the brand.
  ColorScheme toColorScheme(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    );
    return base.copyWith(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primaryTint,
      onPrimaryContainer: primaryDeep,
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: surfaceSecondary,
      onSurfaceVariant: textSecondary,
      outline: border,
      outlineVariant: border,
      error: error,
      onError: onFill,
      errorContainer: errorTint,
      onErrorContainer: textPrimary,
    );
  }

  @override
  ScenovaColors copyWith({
    Color? surface,
    Color? surfaceSecondary,
    Color? textPrimary,
    Color? textSecondary,
    Color? textDisabled,
    Color? placeholder,
    Color? border,
    Color? iconDefault,
    Color? iconActive,
    Color? iconDisabled,
    Color? primary,
    Color? onPrimary,
    Color? primaryTint,
    Color? primaryDeep,
    Color? primaryPressed,
    Color? focusRing,
    Color? success,
    Color? successTint,
    Color? warning,
    Color? warningTint,
    Color? error,
    Color? errorTint,
    Color? info,
    Color? infoTint,
    Color? accent,
    Color? accentTint,
    Color? onFill,
  }) {
    return ScenovaColors(
      surface: surface ?? this.surface,
      surfaceSecondary: surfaceSecondary ?? this.surfaceSecondary,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textDisabled: textDisabled ?? this.textDisabled,
      placeholder: placeholder ?? this.placeholder,
      border: border ?? this.border,
      iconDefault: iconDefault ?? this.iconDefault,
      iconActive: iconActive ?? this.iconActive,
      iconDisabled: iconDisabled ?? this.iconDisabled,
      primary: primary ?? this.primary,
      onPrimary: onPrimary ?? this.onPrimary,
      primaryTint: primaryTint ?? this.primaryTint,
      primaryDeep: primaryDeep ?? this.primaryDeep,
      primaryPressed: primaryPressed ?? this.primaryPressed,
      focusRing: focusRing ?? this.focusRing,
      success: success ?? this.success,
      successTint: successTint ?? this.successTint,
      warning: warning ?? this.warning,
      warningTint: warningTint ?? this.warningTint,
      error: error ?? this.error,
      errorTint: errorTint ?? this.errorTint,
      info: info ?? this.info,
      infoTint: infoTint ?? this.infoTint,
      accent: accent ?? this.accent,
      accentTint: accentTint ?? this.accentTint,
      onFill: onFill ?? this.onFill,
    );
  }

  @override
  ScenovaColors lerp(ThemeExtension<ScenovaColors>? other, double t) {
    if (other is! ScenovaColors) return this;
    return t < 0.5 ? this : other;
  }
}
